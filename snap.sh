#!/bin/sh

FS=$1
ZFS=/sbin/zfs
DATE=$(which date)

if [ -z "$1" ]; then
  echo Usage: $0 FileSystem
  exit 1
fi

if [ ! -x "$ZFS" ]; then
  echo "zfs binary is missing!"
  exit 1
fi

if [ ! -x "$DATE" ]; then
  echo "date binary is missing!"
  exit 1
fi

TIME=$(date +"%Y%m%d-%H%M%S")

if ! $ZFS list -H $FS > /dev/null 2>&1; then
  echo Invalid FileSystem
  exit 1
fi

$ZFS snapshot $FS@snap-$TIME

