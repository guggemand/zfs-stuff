#!/bin/sh

ZFS=$(which zfs)

if [ ! -x "$ZFS" ]; then
  echo "zfs binary is missing!"
  exit 1
fi

DIR=$(dirname $0)

for fs in $($ZFS get -s local -o name -H dlx.dk.sync:remotefs); do
  $DIR/sync.sh $fs
done


