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

LOCALCMD=/sbin/zfs
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

RUNNING=$($LOCALCMD get -H -o value -s local dlx.dk.sync:running $LOCALFS)

if [ -n "$RUNNING" -a "$RUNNING" != "-" ]; then
  if [ -t 1 ]; then
    echo "Last sync is still running!"
  fi
  exit 2
fi

$LOCALCMD set dlx.dk.sync:running=1 $LOCALFS
trap "$LOCALCMD inherit dlx.dk.sync:running $LOCALFS" 0 1 2 3 15

#find newest snapshots
RSNAP=$($REMOTECMD list -t snapshot -s creation -o name -rH $REMOTEFS)
RSNAP=${RSNAP##*@}
LSNAPS=$($LOCALCMD list -t snapshot -s creation -o name -rH $LOCALFS)
LSNAP=${LSNAPS##*@}

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
    SNAP1=$RSNAP
    for SNAP in ${LSNAPS##*@$RSNAP}; do
      SNAP2=${SNAP##*@}
      if [ -t 1 -a -x "$PV" ]; then
        $LOCALCMD send -i $LOCALFS@$SNAP1 $LOCALFS@$SNAP2 | $PV | $REMOTECMD receive -F $REMOTEFS
      else
        $LOCALCMD send -i $LOCALFS@$SNAP1 $LOCALFS@$SNAP2 | $REMOTECMD receive -F $REMOTEFS
      fi
      SNAP1=$SNAP2
    done
    exit
  fi
fi
