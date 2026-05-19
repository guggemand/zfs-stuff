#!/bin/sh

set -e

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

RUNNING=$($LOCALCMD get -H -o value -s local dlx.dk.sync:running "$LOCALFS")

if [ -n "$RUNNING" ] && [ "$RUNNING" != "-" ]; then
  if [ -t 1 ]; then
    echo "Last sync is still running!"
  fi
  exit 2
fi

$LOCALCMD set dlx.dk.sync:running=1 "$LOCALFS"
trap "$LOCALCMD inherit dlx.dk.sync:running $LOCALFS" 0 1 2 3 15

#find newest snapshots
RSNAP=$($REMOTECMD list -t snapshot -s creation -o name -rH "$REMOTEFS")
RSNAP=${RSNAP##*@}
LSNAPS=$($LOCALCMD list -t snapshot -s creation -o name -rH "$LOCALFS")
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

#check if newest snapshot is synced, if not do that
if [ -n "$RSNAP" ]; then
  if [ "$RSNAP" != "$LSNAP" ]; then
    if [ -t 1 ]; then
      echo "now syncing $LOCALFS"
      $LOCALCMD send $SENDARGS -nvI "$LOCALFS@$RSNAP" "$LOCALFS@$LSNAP"
    fi
    SNAP1=$RSNAP
    for SNAP in ${LSNAPS##*@$RSNAP}; do
      SNAP2=${SNAP##*@}
      if [ -t 1 ] && [ -x "$PV" ]; then
        $LOCALCMD send $SENDARGS -i "$LOCALFS@$SNAP1" "$LOCALFS@$SNAP2" | $PV | $REMOTECMD receive -F "$REMOTEFS" || exit 2
      else
        $LOCALCMD send $SENDARGS -i "$LOCALFS@$SNAP1" "$LOCALFS@$SNAP2" | $REMOTECMD receive -F "$REMOTEFS" || exit 2
      fi
      SNAP1=$SNAP2
    done
    exit
  fi
else
  LSNAP=$(echo $LSNAPS)
  LSNAP=${LSNAP%% *}
  LSNAP=${LSNAP##*@}
  if [ -t 1 ]; then
    echo "now syncing $LOCALFS"
    $LOCALCMD send $SENDARGS -nv "$LOCALFS@$LSNAP"
  fi
  if [ -t 1 ] && [ -x "$PV" ]; then
    $LOCALCMD send $SENDARGS "$LOCALFS@$LSNAP" | $PV | $REMOTECMD receive "$REMOTEFS" || exit 2
  else
    $LOCALCMD send $SENDARGS "$LOCALFS@$LSNAP" | $REMOTECMD receive "$REMOTEFS" || exit 2
  fi
fi
