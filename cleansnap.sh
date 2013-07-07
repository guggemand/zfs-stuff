#!/bin/sh
set -e

if [ -z "$5" ]; then
  echo Usage: $0 FileSystem Days Weeks Months Years
  exit 1
fi

export ZFS=/sbin/zfs
export FS=$1
export DAYS=$2
export WEEKS=$3
export MONTHS=$4
export YEARS=$5
export JUSTDOIT=$6

case $(uname) in
  SunOS)
    DATE=/usr/gnu/bin/date
    BASH=/usr/bin/bash
    ;;
  Linux)
    DATE=/bin/date
    BASH=/bin/bash
    ;;
  FreeBSD)
    DATE=/usr/local/bin/gdate
    BASH=/usr/local/bin/bash
    if [ ! -x "$DATE" ]; then
      echo "$DATE not found, install /usr/ports/sysutils/coreutils"
      exit 2
    fi
    if [ ! -x "$BASH" ]; then
      echo "$BASH not found, install /usr/ports/shells/bash"
      exit 2
    fi
    ;;
esac

export DATE

if ! $ZFS list -H $FS > /dev/null 2> /dev/null; then
  echo Invalid FileSystem
  exit 1
fi

$BASH << 'EOF'
  set -e

  i=1;
  for SNAP in $($ZFS list -t snapshot -d 1 -H -o name -s creation $FS); do
    TIME=$($ZFS get -p -o value -H creation $SNAP)
    timetosnap["$TIME"]="$SNAP"
    times[$i]="$TIME"
    i=$(($i+1))
  done

  TIMES=${times[@]}

  # Find all the daily snapshots we want to keep
  for ((i=0;i<$DAYS;i++)); do
    TIME=$($DATE -d "$i days ago 00:00" +%s)
    for j in $TIMES; do
      if [ $j -ge $TIME ]; then
        keeptimes[$j]=$j
        break
      fi
    done
  done

  # Find all the weekly snapshots we want to keep
  for ((i=1;i<=$WEEKS;i++)); do
    TIME=$($DATE -d "$i week ago sunday 00:00" +%s)
    for j in $TIMES; do
      if [ $j -ge $TIME ]; then
        keeptimes[$j]=$j
        break
      fi
    done
  done

  # Find the monthly snapshots we want to keep
  for ((i=0;i<$MONTHS;i++)); do
    TIME=$($DATE +%s -d "$($DATE +%Y-%m-01) -$i month")
    for j in $TIMES; do
      if [ $j -ge $TIME ]; then
        keeptimes[$j]=$j
        break
      fi
    done
  done

  # Find the yearly snapshots we want to keep
  for ((i=0;i<$YEARS;i++)); do
    #TIME=$($DATE +%s -d "$($DATE +%Y-01-01 -d "$i year ago")")
    TIME=$($DATE +%s -d "$($DATE +%Y-01-01) -$i year")
    for j in $TIMES; do
      if [ $j -ge $TIME ]; then
        keeptimes[$j]=$j
        break
      fi
    done
  done

  # We always want to keep snapshots from the last 24 hours
  TIME=$(($($DATE +%s)-60*60*24))
  for i in $TIMES; do
    if [ $i -ge $TIME ]; then
      keeptimes[$i]=$i
    fi
  done

  # We alwasy want to keep the latest snapshot
  NEWEST=$($ZFS get -p -o value -H creation $($ZFS list -t snapshot -d 1 -S creation -H -o name $FS|head -n 1))
  keeptimes[$NEWEST]=$NEWEST

  # We want to delete all other snapshots
  for i in $TIMES; do
    if [ -z ${keeptimes[$i]} ]; then
      snapstodelete[$i]=${timetosnap[$i]}
    else
      snapstokeep[$i]=${timetosnap[$i]}
    fi
  done

  KEEP=${#keeptimes[@]}
  REMOVE=${#snapstodelete[@]}

  if [ $KEEP -lt 1 ]; then
    echo "Nothing to keep?!?"
    exit 1
  fi

  if [ $REMOVE -gt $KEEP ]; then
    echo "Cannot remove more than 50% of the snapshots, try again!"
    echo "All: ${timetosnap[@]}"
    echo "Remove: ${snapstodelete[@]}"
    echo "Keep: ${snapstokeep[@]}"
    # hidden feature :)
    if [ "$JUSTDOIT" != "JustDoIt" ]; then
      exit 1
    fi
  fi

  for i in $TIMES; do
    SNAP=${timetosnap[$i]}
    if [ -z ${keeptimes[$i]} ]; then
      if [ -t 1 ]; then
        echo "$SNAP slettes!"
      fi
      $ZFS destroy $SNAP
    fi
  done
EOF

