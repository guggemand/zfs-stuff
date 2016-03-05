#!/bin/sh
#
# Helper script for sync.sh
# It will send the stream compressed over ssh to remotehost.
# If mbuffer is installed it will use a 1G buffer to speed up the transfer.
#
# set dlx.dk.sync:remotecmd to "sendwithpigz.sh user@remotehost"

if [ -z "$1" -o -z "$2" ]; then
  echo Usage: $0 user@host list/receive
  exit 1
fi

REMOTEHOST=$1
MBUFFER=$(which mbuffer)
PATH=$PATH:/usr/local/bin:/usr/local/sbin

shift

if [ "$1" = "receive" ]; then
  if [ -x "$MBUFFER" ]; then
    $MBUFFER -m 1G -q -s 128k | pigz | ssh $REMOTEHOST pigz -d \| /sbin/zfs $*
  else
    pigz | ssh $REMOTEHOST pigz -d \| /sbin/zfs $*
  fi
elif [ "$1" = "list" ]; then
  ssh $REMOTEHOST /sbin/zfs $*
else
  echo "only \"list\" and \"receive\" is supported"
  exit 1
fi

