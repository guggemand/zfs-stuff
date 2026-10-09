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

ALLOWED_FS=$1

# Is $1 the allowed filesystem or a descendant of it?  With no restriction
# configured, everything is allowed (legacy behavior).
fs_allowed() {
  [ -z "$ALLOWED_FS" ] && return 0
  case "$1" in
    "$ALLOWED_FS"|"$ALLOWED_FS"/*) return 0 ;;
  esac
  return 1
}

set -f
# shellcheck disable=SC2086  # word splitting is the point; set -f blocks globs
set -- $SSH_ORIGINAL_COMMAND

if [ "$1 $2 $3" = "pigz -d |" ]; then
  PIGZ=1
  shift 3
fi

if [ "$1" = "/sbin/zfs" ] || [ "$1" = "zfs" ]; then
  case "$2" in
    "list")
        # Current sync.sh form
        if [ "$3 $4 $5 $6 $7 $8 $9 ${10} ${11}" = "-t snapshot -s creation -o name -d 1 -H" ]; then
          "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}"
          exit $?
        fi
        # Legacy recursive form, kept so old senders keep working during rollout
        if [ "$3 $4 $5 $6 $7 $8 $9" = "-t snapshot -s creation -o name -rH" ]; then
          "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}"
          exit $?
        fi
      ;;

    "receive")
        if [ "$3" = "-F" ]; then
          TARGETFS=$4
        else
          TARGETFS=$3
        fi
        if ! fs_allowed "$TARGETFS"; then
          echo "receive into '$TARGETFS' not allowed" >&2
          exit 1
        fi
        if [ "$3" = "-F" ]; then
          if [ -n "$PIGZ" ]; then
            pigz -d | "$1" "$2" "$3" "$4"
          else
            "$1" "$2" "$3" "$4"
          fi
          exit $?
        else
          if [ -n "$PIGZ" ]; then
            pigz -d | "$1" "$2" "$3"
          else
            "$1" "$2" "$3"
          fi
          exit $?
        fi
      ;;
  esac
fi

echo "'$SSH_ORIGINAL_COMMAND' not allowed" >&2
exit 1

