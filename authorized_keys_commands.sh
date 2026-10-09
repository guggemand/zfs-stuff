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
# SSH_ORIGINAL_COMMAND must be exactly one of a small set of canonical forms
# followed by a single ZFS dataset name.  Anything else is rejected.

ALLOWED_FS=$1

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
    exec "$ZFS" list -t snapshot -s creation -o name -d 1 -H "$FS"
    ;;
  # Legacy recursive form, kept so old senders keep working during rollout
  "list -t snapshot -s creation -o name -rH")
    [ -z "$PIGZ" ] || deny
    exec "$ZFS" list -t snapshot -s creation -o name -rH "$FS"
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
