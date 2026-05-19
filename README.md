# ZFS Scripts

Scripts to automate creation, replication, and cleanup of ZFS snapshots between two systems. Supports Linux, Solaris, and FreeBSD.

## Overview

The typical workflow is:

1. **snap.sh** -- create a timestamped snapshot
2. **sync.sh** -- replicate snapshots to a remote host via `zfs send | zfs receive`
3. **cleansnap.sh** -- prune old snapshots based on a retention policy

**syncall.sh** and **snapandsync.sh** combine these steps for convenience. **check_zfs_snapshots.sh** provides Nagios-compatible monitoring.

## Scripts

### snap.sh

Creates a timestamped ZFS snapshot (`snap-YYYYMMDD-HHMMSS`).

```
snap.sh <filesystem>
```

### sync.sh

Replicates snapshots from a local filesystem to a remote one using `zfs send | zfs receive` over SSH. Reads connection details from ZFS properties (see [Configuration](#configuration)).

- Sends only incremental snapshots when the remote already has a common base
- Uses `pv` for progress display if available and running interactively
- Sets a `dlx.dk.sync:running` lock property to prevent concurrent syncs

```
sync.sh <filesystem>
```

### syncall.sh

Runs `sync.sh` for every filesystem that has the `dlx.dk.sync:remotefs` property set locally. Continues syncing remaining filesystems if one fails, exiting with a non-zero code if any sync failed.

```
syncall.sh
```

### snapandsync.sh

Convenience wrapper that runs `snap.sh` followed by `sync.sh` for a single filesystem.

```
snapandsync.sh <filesystem>
```

### cleansnap.sh

Prunes snapshots according to a retention policy. Always keeps snapshots from the last 24 hours and the most recent snapshot. Refuses to delete more than 50% of snapshots in one run (override with `JustDoIt` as the 6th argument).

Retention counts specify how many snapshots to keep per period (daily, weekly, monthly, yearly). Each period keeps the first snapshot on or after the period boundary.

- **Days** -- includes today, so 7 keeps today through 6 days ago
- **Weeks** -- counts past Sundays, so 4 keeps the last 4 Sundays
- **Months** -- includes the current month, so 6 keeps this month through 5 months ago
- **Years** -- includes the current year, so 3 keeps this year through 2 years ago

Note: monthly and yearly include the current period (which is usually already covered by daily/weekly), so you may want to add 1 to get the number of *past* periods you expect.

```
cleansnap.sh <filesystem> <days> <weeks> <months> <years> [JustDoIt]
```

```sh
# Keep 7 daily, 4 weekly (last 4 Sundays), 6 monthly (this month + 5 prior),
# 3 yearly (this year + 2 prior)
cleansnap.sh tank/data 7 4 6 3
```

**Bookmark support:** Append `:<count>` to any retention value to extend retention with ZFS bookmarks beyond the snapshot count. Bookmarks allow incremental sends even after the snapshot is gone.

```sh
# Keep 7 daily snapshots + 2 additional days as bookmarks (days 8-9),
# 4 weekly snapshots + 1 additional week as a bookmark, 3 monthly, 2 yearly
cleansnap.sh tank/data 7:2 4:1 3 2
```

### check_zfs_snapshots.sh

Nagios/Icinga-compatible check that alerts when the newest snapshot on a filesystem is older than a threshold.

```
check_zfs_snapshots.sh <default_max_minutes> <filesystem>[:<max_minutes>] ...
```

```sh
# Warn if any snapshot is older than 60 minutes; tank/logs gets a 30-minute threshold
check_zfs_snapshots.sh 60 tank/data tank/logs:30
```

Exits 0 (OK) or 2 (CRITICAL). Outputs performance data compatible with Nagios.

### sendwithpigz.sh

Drop-in replacement for the remote `zfs` command that compresses the stream with `pigz` before sending over SSH. Optionally buffers with `mbuffer` (1 GB buffer) if installed.

Set `dlx.dk.sync:remotecmd` to point to this script instead of `ssh user@host /sbin/zfs`:

```sh
zfs set dlx.dk.sync:remotecmd="sendwithpigz.sh user@host" tank/data
```

### authorized_keys_commands.sh

SSH forced-command wrapper for the **receiving** host's `~/.ssh/authorized_keys`. Restricts the SSH key to only allow `zfs list` and `zfs receive` commands (with optional `pigz` decompression), preventing arbitrary command execution.

```
command="/path/to/authorized_keys_commands.sh",no-port-forwarding,no-X11-forwarding,no-pty ssh-rsa ...
```

## Installation

Place the scripts in a directory on your `$PATH`, for example `/usr/local/sbin`. The scripts reference each other by relative path, so keep them together.

```sh
cp *.sh /usr/local/sbin/
chmod +x /usr/local/sbin/*.sh
```

### Prerequisites

| Platform | Required packages |
|----------|------------------|
| FreeBSD  | `sysutils/coreutils` (`gdate`), `shells/bash` |
| Linux    | `pv` (optional, for progress display) |
| Solaris  | GNU date at `/usr/gnu/bin/date` |

### Optional

| Package  | Effect |
|----------|--------|
| `pv`     | Shows transfer progress when running interactively |
| `pigz`   | Parallel gzip compression via `sendwithpigz.sh` |
| `mbuffer` | 1 GB send buffer to smooth out transfer spikes (used by `sendwithpigz.sh`) |

## Configuration

`sync.sh` (and scripts that call it) reads the following ZFS properties from the local filesystem:

| Property | Description |
|----------|-------------|
| `dlx.dk.sync:remotecmd` | *(required)* Command used to invoke `zfs` on the remote side (e.g. `ssh user@host /sbin/zfs`) |
| `dlx.dk.sync:remotefs` | *(required)* Target filesystem on the remote host |
| `dlx.dk.sync:sendargs` | *(optional)* Extra arguments passed to `zfs send` (e.g. `-w` for raw/encrypted sends) |

```sh
zfs set dlx.dk.sync:remotecmd="ssh user@host /sbin/zfs" tank/data
zfs set dlx.dk.sync:remotefs="backup/data" tank/data

# Replicate an encrypted dataset without decrypting
zfs set dlx.dk.sync:sendargs="-w" tank/data

# Use pigz + mbuffer for faster transfers
zfs set dlx.dk.sync:remotecmd="sendwithpigz.sh user@host" tank/data
```

## Securing the SSH Key

Use `authorized_keys_commands.sh` on the receiving host to restrict the dedicated sync SSH key to only the commands that `sync.sh` needs:

```
# ~/.ssh/authorized_keys on the remote host
command="/usr/local/sbin/authorized_keys_commands.sh",no-port-forwarding,no-X11-forwarding,no-pty ssh-rsa AAAA...
```

This allows `zfs list` and `zfs receive` but rejects any other SSH command.
