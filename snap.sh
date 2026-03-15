#!/bin/sh

set -e

ZFS=${ZFS:-/sbin/zfs}
DATE=${DATE:-$(command -v date)}

if [ -z "$1" ]; then
  echo "Usage: $0 FileSystem" >&2
  exit 1
fi

FS=$1

if [ ! -x "$ZFS" ]; then
  echo "zfs binary is missing!" >&2
  exit 1
fi

if [ ! -x "$DATE" ]; then
  echo "date binary is missing!" >&2
  exit 1
fi

TIME=$($DATE +"%Y%m%d-%H%M%S")

if ! $ZFS list -H "$FS" > /dev/null 2>&1; then
  echo "Invalid FileSystem" >&2
  exit 1
fi

$ZFS snapshot "$FS@snap-$TIME"

