#!/bin/sh

# Nagios check for checking the age of the newest snapshot on one or more zfs filesystems.

if [ -z "$1" -o -z "$2" ]; then
  echo Usage: $0 DefaultMaxMinutes FileSystem[:MaxMinutes] FileSystem[:MaxMinutes] ..
  exit 1
fi

NOW=$(date +%s)
DEFMAXDIFF=$(($1*60))
ZFS=/sbin/zfs

shift

for i in $*; do
  FS=${i%%:*}
  if [ "$FS" = "$i" ]; then
    MAXDIFF=$DEFMAXDIFF
  else
    MAXDIFF=$((${i##*:}*60))
  fi

  SNAP=$($ZFS list -t snapshot -d 1 -H -o name -s creation $FS 2> /dev/null | tail -n 1 )
  if [ -z $SNAP ]; then
    echo "ERROR: $FS does not exist"
    exit 2
  fi
  TIME=$($ZFS get -p -o value -H creation $SNAP)
  DIFF=$(($NOW-$TIME))
  if [ $DIFF -gt $MAXDIFF ]; then
    if [ -n "$ERRORS" ]; then
      ERRORS="$ERRORS\n$SNAP"
    else
      ERRORS="$SNAP"
    fi
  fi
  if [ -n "$PERFDATA" ]; then
    PERFDATA="$PERFDATA $FS=$DIFF;;$MAXDIFF"
  else
    PERFDATA="$FS=$DIFF;;$MAXDIFF"
  fi
done

if [ -n "$ERRORS" ]; then
  printf "ERROR: Snapshots to old\n$ERRORS | $PERFDATA\n"
  exit 2
fi

echo "OK: ZFS snapshots - No failures detected | $PERFDATA"
exit 0


