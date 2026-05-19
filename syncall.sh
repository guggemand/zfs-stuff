#!/bin/sh

set -e

ZFS=${ZFS:-/sbin/zfs}

if [ ! -x "$ZFS" ]; then
  echo "zfs binary is missing!" >&2
  exit 1
fi

DIR=$(dirname "$0")

RC=0
for fs in $($ZFS get -s local -t filesystem,volume -o name -H dlx.dk.sync:remotefs); do
  $DIR/sync.sh "$fs" || RC=$?
done
exit $RC


