#!/bin/sh
# shellcheck disable=SC2086  # unquoted $ZFS is intentional
set -e

ZFS=${ZFS:-/sbin/zfs}

if [ -z "$1" ]; then
  echo "Usage: $0 FileSystem" >&2
  exit 1
fi

if [ ! -x "$ZFS" ]; then
  echo "zfs binary is missing!" >&2
  exit 1
fi

DIR=$(dirname "$0")
TANK=$1

if ! $ZFS list -H "$TANK" > /dev/null 2> /dev/null; then
  echo "Invalid FileSystem" >&2
  exit 1
fi

"$DIR/snap.sh" "$1"
"$DIR/sync.sh" "$1"
