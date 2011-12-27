#!/bin/sh

ZFS=$(which zfs)

if [ -z "$1" ]; then
  echo Usage: $0 FileSystem
  exit 1
fi

if [ ! -x "$ZFS" ]; then
  echo "zfs binary is missing!"
  exit 1
fi

DIR=$(dirname $0)
TANK=$1

if ! $ZFS list -H $TANK > /dev/null 2> /dev/null; then
  echo Invalid FileSystem
  exit 1
fi

if $DIR/snap.sh $1; then
  $DIR/sync.sh $1
fi

