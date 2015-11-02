# ZFS Scripts

Scripts to help automate creation, replication and cleanup of zfs snapshots
between two systems running ZFS. This should work on Linux, Solaris and FreeBSD.

## Scripts

- check_zfs_snapshots.sh

  Nagios check for checking the age of the newest snapshot on one or more zfs filesystems

- cleansnap.sh

  Clean up snapshots

- syncall.sh

  Execute synchronization (replication) on all filesystems that require it

- sync.sh

  Synchronise (replicate) using send + receive over ssh

- sendwithpigz.sh

  Helper script for send.sh - will use pigz and mbuffer to compress/speed up transfer
  if remotecmd is explicitly set to use this script

- snap.sh

  Create ZFS snapshot for given filesystem

- snapandsync.sh

  Creates ZFS snapshots for a given filesystem, then proceeds to replicate it using sync.sh


# Installation

Place the scripts where you want, for example in /usr/local/sbin

## Prerequisites (FreeBSD)

* sysutils/coreutils
* shells/bash
* sysutils/pv

## Optional: pigz and mbuffer

If mbuffer is installed it will use a 1G buffer to speed up the transfer

pigz allows for parallelizing gzip

## Configuration

A couple of custom ZFS properties need to be defined for the script(s) to
work.

- dlx.dk.sync:remotecmd
- dlx.dk.sync:remotefs

For example

~~~
# zfs set dlx.dk.sync:remotecmd="ssh user@host /sbin/zfs" local/fs
# zfs set dlx.dk.sync:remotefs="remote/fs" local/fs
~~~
