#!/bin/sh

set -e

#
# commands script for openssh authorized_keys
#
# Use this in ~/.ssh/authorized_keys
# command="/path/to/authorized_keys_commands.sh",no-port-forwarding,no-X11-forwarding,no-pty ssh-rsa .........
#
# An optional argument restricts zfs receive to one filesystem and its
# descendants (recommended -- without it the key may receive -F into ANY
# dataset):
# command="/path/to/authorized_keys_commands.sh backup/data",... ssh-rsa ...
#
# --allow-send additionally allows zfs send of snapshots of that filesystem
# and its descendants (e.g. for a host that pulls backups), and limits zfs
# list to the same tree.  It requires the filesystem argument:
# command="/path/to/authorized_keys_commands.sh --allow-send tank/data",... ssh-rsa ...
#
# SSH_ORIGINAL_COMMAND must be exactly one of a small set of canonical forms
# followed by a single ZFS dataset name.  Anything else is rejected.

ALLOW_SEND=
if [ "$1" = "--allow-send" ]; then
  ALLOW_SEND=1
  shift
fi
ALLOWED_FS=$1

# A misconfigured key line refuses everything rather than silently falling
# back to fewer restrictions.
if [ $# -gt 1 ] || { [ -n "$ALLOW_SEND" ] && [ -z "$ALLOWED_FS" ]; }; then
  echo "authorized_keys_commands.sh: usage: [--allow-send] [filesystem]; --allow-send requires a filesystem" >&2
  exit 1
fi

deny() {
  echo "'$SSH_ORIGINAL_COMMAND' not allowed" >&2
  exit 1
}

# Is $1 the allowed filesystem or a descendant of it?  With no restriction
# configured, everything is allowed (legacy behavior).
fs_allowed() {
  [ -z "$ALLOWED_FS" ] && return 0
  case "$1" in
    "$ALLOWED_FS"|"$ALLOWED_FS"/*) return 0 ;;
  esac
  return 1
}

# With --allow-send, zfs list is limited to the allowed tree as well
check_list_target() {
  if [ -n "$ALLOW_SEND" ] && ! fs_allowed "$FS"; then
    echo "list of '$FS' not allowed" >&2
    exit 1
  fi
}

# zfs send [-w] [-c] [-L] [-e] [-i|-I SOURCE] SNAPSHOT
#   SNAPSHOT: a snapshot of the allowed filesystem or a descendant
#   SOURCE:   a snapshot or bookmark of the same dataset as SNAPSHOT
run_send() {
  [ -n "$ALLOW_SEND" ] || deny
  [ -z "$PIGZ" ] || deny
  case "$FS" in
    *@*) ;;
    *) deny ;;
  esac
  if ! fs_allowed "${FS%%@*}"; then
    echo "send from '$FS' not allowed" >&2
    exit 1
  fi

  # Rebuild the argument list word by word -- no word splitting anywhere
  set -- send
  REST=${CMD#"$ZFS send"}
  REST=${REST# }
  while [ -n "$REST" ]; do
    WORD=${REST%% *}
    if [ "$WORD" = "$REST" ]; then
      REST=
    else
      REST=${REST#* }
    fi
    case "$WORD" in
      -w|-c|-L|-e)
        set -- "$@" "$WORD"
        ;;
      -i|-I)
        # The source must be the one remaining word
        case "$REST" in
          ""|*" "*|*[!A-Za-z0-9_/.:@#-]*) deny ;;
        esac
        case "$REST" in
          *@*|*#*) ;;
          *) deny ;;
        esac
        if [ "${REST%%[@#]*}" != "${FS%%@*}" ]; then
          deny
        fi
        set -- "$@" "$WORD" "$REST"
        REST=
        ;;
      *)
        deny
        ;;
    esac
  done
  exec "$ZFS" "$@" "$FS"
}

check_receive_target() {
  if ! fs_allowed "$FS"; then
    echo "receive into '$FS' not allowed" >&2
    exit 1
  fi
}

# FS = the last space-separated word, CMD = everything before it.  A command
# without a space leaves CMD equal to the whole command, which matches
# nothing below and is denied.
FS=${SSH_ORIGINAL_COMMAND##* }
CMD=${SSH_ORIGINAL_COMMAND% *}

# FS must be a non-empty dataset name made of ZFS-name-safe characters only.
case "$FS" in
  ""|*[!A-Za-z0-9_/.:@#-]*) deny ;;
esac

# sendwithpigz.sh wraps the receive stream in pigz
PIGZ=
case "$CMD" in
  "pigz -d | "*)
    PIGZ=1
    CMD=${CMD#"pigz -d | "}
    ;;
esac

# Run the zfs the sender asked for, but only these two spellings
case "$CMD" in
  "zfs "*) ZFS=zfs ;;
  "/sbin/zfs "*) ZFS=/sbin/zfs ;;
  *) deny ;;
esac

case "${CMD#"$ZFS "}" in
  "list -t snapshot -s creation -o name -d 1 -H")
    [ -z "$PIGZ" ] || deny
    check_list_target
    exec "$ZFS" list -t snapshot -s creation -o name -d 1 -H "$FS"
    ;;
  # Legacy recursive form, kept so old senders keep working during rollout
  "list -t snapshot -s creation -o name -rH")
    [ -z "$PIGZ" ] || deny
    check_list_target
    exec "$ZFS" list -t snapshot -s creation -o name -rH "$FS"
    ;;
  "send"|"send "*)
    run_send
    ;;
  "receive -F")
    check_receive_target
    if [ -n "$PIGZ" ]; then
      pigz -d | "$ZFS" receive -F "$FS"
      exit $?
    fi
    exec "$ZFS" receive -F "$FS"
    ;;
  "receive")
    check_receive_target
    if [ -n "$PIGZ" ]; then
      pigz -d | "$ZFS" receive "$FS"
      exit $?
    fi
    exec "$ZFS" receive "$FS"
    ;;
esac

deny
