#!/bin/sh
# The script re-execs itself under bash below; lint the body as bash.
# shellcheck shell=bash
# SC2086: unquoted $LOCALCMD/$REMOTECMD/$SENDARGS word splitting is intentional.
# SC2064: the trap must capture $LOCALCMD/$LOCALFS at set time.
# shellcheck disable=SC2086,SC2064

# Re-exec under bash so we can use `set -o pipefail`; without it a failing
# `zfs send` is silently masked by a successful `zfs receive`.  FreeBSD cron
# has a minimal PATH, so we locate bash by absolute path rather than via env.
if [ -z "$BASH_VERSION" ]; then
  case "$(uname)" in
    SunOS)   BASH=${BASH:-/usr/bin/bash} ;;
    FreeBSD) BASH=${BASH:-/usr/local/bin/bash} ;;
    *)       BASH=${BASH:-/bin/bash} ;;
  esac
  if [ ! -x "$BASH" ]; then
    echo "$BASH not found" >&2
    exit 2
  fi
  exec "$BASH" "$0" "$@"
fi

set -e
set -o pipefail

#
# Syncs zfs filesystem with send / receive
#
# Needs two custom properties on the local fs
#  - dlx.dk.sync:remotecmd : command to call remote zfs binary
#  - dlx.dk.sync:remotefs : the receiving filesystem
#
# Example
#  zfs set dlx.dk.sync:remotecmd="ssh user@host /sbin/zfs" local/fs
#  zfs set dlx.dk.sync:remotefs="remote/fs" local/fs
#  zfs set dlx.dk.sync:sendargs="-w" local/fs
#

LOCALCMD=${LOCALCMD:-/sbin/zfs}
PV=${PV:-$(command -v pv)}

if [ -z "$1" ]; then
  echo "Usage: $0 FileSystem" >&2
  exit 1
fi

if [ ! -x "$LOCALCMD" ]; then
  echo "zfs binary is missing!" >&2
  exit 1
fi

LOCALFS=$1

if ! $LOCALCMD list -H "$LOCALFS" > /dev/null 2> /dev/null; then
  echo "Invalid FileSystem" >&2
  exit 1
fi

REMOTEFS=$($LOCALCMD get -H -o value dlx.dk.sync:remotefs "$LOCALFS")
REMOTECMD=$($LOCALCMD get -H -o value dlx.dk.sync:remotecmd "$LOCALFS")
SENDARGS=$($LOCALCMD get -s local,default,inherited,temporary,received -H -o value dlx.dk.sync:sendargs "$LOCALFS")

if [ "$REMOTEFS" = "-" ]; then
  echo "Missing dlx.dk.sync:remotefs property" >&2
  exit 1
fi

if [ "$REMOTECMD" = "-" ]; then
  echo "Missing dlx.dk.sync:remotecmd property" >&2
  exit 1
fi

# The lock property holds the PID of the sync that took it, so a later run
# can tell a live sync (benign overlap, stay quiet for cron) from a stale
# lock left behind by a crash (warn once, clear, continue).
RUNNING=$($LOCALCMD get -H -o value -s local dlx.dk.sync:running "$LOCALFS")

if [ -n "$RUNNING" ] && [ "$RUNNING" != "-" ]; then
  if kill -0 "$RUNNING" 2>/dev/null; then
    if [ -t 1 ]; then
      echo "Last sync is still running!"
    fi
    exit 2
  fi
  echo "Clearing stale sync lock for $LOCALFS (pid $RUNNING is gone)" >&2
fi

$LOCALCMD set dlx.dk.sync:running=$$ "$LOCALFS"
trap "$LOCALCMD inherit dlx.dk.sync:running $LOCALFS" 0 1 2 3 15

# Find newest snapshots.  -d 1 lists only this filesystem's own snapshots;
# a recursive list (-r) would mix in child-dataset snapshots and corrupt the
# incremental send plan when children share snapshot names.
#
# A receiver still running an older authorized_keys_commands.sh rejects -d 1
# and only allows the recursive -rH form.  Fall back to that and keep only
# REMOTEFS's own snapshots -- children show up as "$REMOTEFS/child@snap".
#
# If both forms fail, the remote filesystem most likely does not exist yet
# (first sync).  Carry on with no remote snapshots: the full send below then
# creates it.  That receive runs without -F, so if the list failed for some
# other reason it cannot overwrite an existing filesystem -- it just fails.
own_snapshots() {
  local name
  while IFS= read -r name; do
    if [[ $name == "$1@"* ]]; then
      printf '%s\n' "$name"
    fi
  done
}
if ! RSNAP=$($REMOTECMD list -t snapshot -s creation -o name -d 1 -H "$REMOTEFS" 2>/dev/null); then
  if RSNAP=$($REMOTECMD list -t snapshot -s creation -o name -rH "$REMOTEFS" | own_snapshots "$REMOTEFS"); then
    if [ -t 1 ]; then
      echo "Remote rejected 'zfs list -d 1', fell back to recursive list" >&2
    fi
  else
    echo "Cannot list snapshots of $REMOTEFS, assuming it does not exist yet; sending a full stream to create it" >&2
    RSNAP=
  fi
fi
RSNAP=${RSNAP##*@}
LSNAPS=$($LOCALCMD list -t snapshot -s creation -o name -d 1 -H "$LOCALFS")
LSNAP=${LSNAPS##*@}

if [ -z "$LSNAPS" ]; then
  echo "No local snapshots found for $LOCALFS" >&2
  exit 2
fi

#check if the newest remote snapshot exist locally, if not error
if [ -n "$RSNAP" ]; then
  if ! $LOCALCMD list "$LOCALFS@$RSNAP" > /dev/null 2>&1; then
    echo "$RSNAP does not exist locally!!" >&2
    exit 2
  fi
fi

# Nothing to do when the remote already has the newest local snapshot.
if [ -n "$RSNAP" ] && [ "$RSNAP" = "$LSNAP" ]; then
  exit
fi

if [ -n "$RSNAP" ]; then
  # Catch up an existing remote: incremental from RSNAP to the latest local.
  if [ -t 1 ]; then
    echo "now syncing $LOCALFS"
    $LOCALCMD send $SENDARGS -nvI "$LOCALFS@$RSNAP" "$LOCALFS@$LSNAP"
  fi
  SNAP1=$RSNAP
else
  # Fresh remote: full-send the oldest local snapshot, then fall through to
  # the incremental loop so every newer snapshot is sent in the same run.
  SNAP1=${LSNAPS%%$'\n'*}
  SNAP1=${SNAP1##*@}
  if [ -t 1 ]; then
    echo "now syncing $LOCALFS"
    $LOCALCMD send $SENDARGS -nv "$LOCALFS@$SNAP1"
    if [ "$SNAP1" != "$LSNAP" ]; then
      $LOCALCMD send $SENDARGS -nvI "$LOCALFS@$SNAP1" "$LOCALFS@$LSNAP"
    fi
  fi
  if [ -t 1 ] && [ -x "$PV" ]; then
    $LOCALCMD send $SENDARGS "$LOCALFS@$SNAP1" | $PV | $REMOTECMD receive "$REMOTEFS" || exit 2
  else
    $LOCALCMD send $SENDARGS "$LOCALFS@$SNAP1" | $REMOTECMD receive "$REMOTEFS" || exit 2
  fi
fi

for SNAP in ${LSNAPS##*@"$SNAP1"}; do
  SNAP2=${SNAP##*@}
  if [ -t 1 ] && [ -x "$PV" ]; then
    $LOCALCMD send $SENDARGS -i "$LOCALFS@$SNAP1" "$LOCALFS@$SNAP2" | $PV | $REMOTECMD receive -F "$REMOTEFS" || exit 2
  else
    $LOCALCMD send $SENDARGS -i "$LOCALFS@$SNAP1" "$LOCALFS@$SNAP2" | $REMOTECMD receive -F "$REMOTEFS" || exit 2
  fi
  SNAP1=$SNAP2
done
