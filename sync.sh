#!/bin/sh
#
# Syncs zfs filesystem with send / receive
#
# Needs two custom properties on the local fs
#  - dlx.dk.sync:remotecmd : command to call remote zfs binary
#  - dlx.dk.sync:remotefs : the receiving filesystem
#
# Example
#  zfs set dlx.dk.sync:remotecmd="ssh user@host /sbin/zfs" local/fs
#  zfs set dlx.dk.sync:remotefs="remote/fs" local/fs
#

LOCALCMD=$(which zfs)
PV=$(which pv)

if [ -z "$1" ]; then
  echo Usage: $0 FileSystem
  exit 1
fi

if [ ! -x "$LOCALCMD" ]; then
  echo "zfs binary is missing!"
  exit 1
fi

LOCALFS=$1

if ! $LOCALCMD list -H $LOCALFS > /dev/null 2> /dev/null; then
  echo Invalid FileSystem
  exit 1
fi

REMOTEFS=$($LOCALCMD get -H -o value dlx.dk.sync:remotefs $LOCALFS)
REMOTECMD=$($LOCALCMD get -H -o value dlx.dk.sync:remotecmd $LOCALFS)

if [ "$REMOTEFS" = "-" ]; then
  echo Missing dlx.dk.sync:remotefs property
  exit 1
fi

if [ "$REMOTECMD" = "-" ]; then
  echo Missing dlx.dk.sync:remotecmd property
  exit 1
fi

RUNNING=$($LOCALCMD get -H -o value dlx.dk.sync:running $LOCALFS)

if [ "$RUNNING" != "-" ]; then
  fail=$(($RUNNING+1))
  $LOCALCMD set dlx.dk.sync:running=$fail $LOCALFS
  echo "Last sync is stil running! ($RUNNING)"
  exit 2
fi

$LOCALCMD set dlx.dk.sync:running=1 $LOCALFS
trap "$LOCALCMD set dlx.dk.sync:running=- $LOCALFS" 0 1 2 3 15

#find newest snapshots
RSNAP=$($REMOTECMD list -t snapshot -s creation -o name -rH $REMOTEFS)
RSNAP=${RSNAP##*@}
LSNAP=$($LOCALCMD list -t snapshot -s creation -o name -rH $LOCALFS)
LSNAP=${LSNAP##*@}

#check if the newest remote snapshot exits locally, if not error
if [ -n $RSNAP ]; then
  if ! $LOCALCMD list $LOCALFS@$RSNAP > /dev/null 2>&1; then
    echo $RSNAP does not exits locally!!
    exit 2
  fi
fi

#check if newest snapshot is synced, if not do that
if [ -n $RSNAP ]; then
  if [ "$RSNAP" != "$LSNAP" ]; then
    if [ -t 1 ]; then
      echo now syncing from $RSNAP to $LSNAP
    fi
    if [ -t 1 -a -x "$PV" ]; then
      $LOCALCMD send -I $LOCALFS@$RSNAP $LOCALFS@$LSNAP | $PV | $REMOTECMD receive -F $REMOTEFS
    else
      $LOCALCMD send -I $LOCALFS@$RSNAP $LOCALFS@$LSNAP | $REMOTECMD receive -F $REMOTEFS
    fi
    exit
  fi
fi
