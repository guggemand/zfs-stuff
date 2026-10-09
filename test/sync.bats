#!/usr/bin/env bats

load test_helper

setup() {
  common_setup
  use_mock_zfs

  export MOCK_REMOTE_LOG="$TEST_TMPDIR/remote.log"
  touch "$MOCK_REMOTE_LOG"

  # sync.sh uses $LOCALCMD instead of $ZFS for the local zfs binary
  export LOCALCMD="$ZFS"

  # Per-property defaults for sync.sh.  SENDARGS is deliberately left unset:
  # the mock then emits nothing, matching real zfs behavior for an unset
  # property queried with -s source filtering.
  export MOCK_ZFS_PROP_REMOTECMD="$MOCK_DIR/remote_zfs"
  export MOCK_ZFS_PROP_REMOTEFS="backup/data"
  export MOCK_ZFS_PROP_RUNNING="-"

  # Remote mock reads snapshots from its own file
  export MOCK_REMOTE_SNAPSHOTS="$TEST_TMPDIR/remote_snapshots.txt"
  touch "$MOCK_REMOTE_SNAPSHOTS"

  export PV="/nonexistent/pv"
}

teardown() {
  common_teardown
}

# add_snap (from test_helper) writes to MOCK_ZFS_SNAPSHOTS -- alias for clarity
add_local_snap() {
  add_snap "$@"
}

# Helper: add a remote snapshot (name + epoch)
add_remote_snap() {
  printf '%s\t%s\n' "$1" "$2" >> "$MOCK_REMOTE_SNAPSHOTS"
}

# --- Argument validation ---

@test "exits with error when no arguments given" {
  run "$SYNC"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "exits with error for invalid filesystem" {
  export MOCK_ZFS_VALID_FS="tank/other"
  run "$SYNC" tank/data
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid FileSystem"* ]]
}

@test "runs without pv installed" {
  # Under set -e a failing command substitution in an assignment aborts the
  # script, so a missing pv must not end it silently.
  run env -u PV PATH=/nonexistent /bin/bash "$SYNC"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

# --- Property validation ---

@test "exits with error when remotefs property is missing" {
  export MOCK_ZFS_PROP_REMOTEFS="-"
  run "$SYNC" tank/data
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing dlx.dk.sync:remotefs property"* ]]
}

@test "exits with error when remotecmd property is missing" {
  export MOCK_ZFS_PROP_REMOTECMD="-"
  run "$SYNC" tank/data
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing dlx.dk.sync:remotecmd property"* ]]
}

# --- Lock detection ---

@test "exits 2 quietly when a live sync is already running" {
  # Add snapshots so the script would succeed if not for the running check
  add_local_snap "tank/data@snap1" "1000"
  add_remote_snap "backup/data@snap1" "1000"
  # Lock held by a live process (this test shell) -- benign overlap
  export MOCK_ZFS_PROP_RUNNING="$$"
  run "$SYNC" tank/data
  [ "$status" -eq 2 ]
  # Benign overlap must stay quiet when not on a TTY, or cron mails on
  # every sync that outlasts its interval
  [ -z "$output" ]
  # Verify it stopped before listing snapshots
  log_not_contains "$MOCK_ZFS_LOG" "zfs list -t snapshot"
}

@test "clears a stale lock and syncs when the lock holder is dead" {
  add_local_snap "tank/data@snap1" "1000"
  add_remote_snap "backup/data@snap1" "1000"

  # Take a PID that is guaranteed dead: spawn and reap a short-lived process
  sh -c 'true' &
  DEAD_PID=$!
  wait "$DEAD_PID"
  export MOCK_ZFS_PROP_RUNNING="$DEAD_PID"

  run "$SYNC" tank/data
  [ "$status" -eq 0 ]
  # The recovery is warned about once (visible in cron mail)
  [[ "$output" == *"Clearing stale sync lock"* ]]
  # The sync proceeded: took a fresh lock and released it
  grep -Eq "zfs set dlx.dk.sync:running=[0-9]+ tank/data" "$MOCK_ZFS_LOG"
  grep -q "zfs inherit dlx.dk.sync:running tank/data" "$MOCK_ZFS_LOG"
}

# --- Snapshot validation ---

@test "exits 2 when no local snapshots exist" {
  # Empty snapshots files -- no local or remote snapshots
  run "$SYNC" tank/data
  [ "$status" -eq 2 ]
  [[ "$output" == *"No local snapshots found"* ]]
}

@test "exits 2 when newest remote snapshot does not exist locally" {
  add_local_snap "tank/data@snap1" "1000"
  add_local_snap "tank/data@snap2" "2000"
  add_remote_snap "backup/data@snap-gone" "1500"

  run "$SYNC" tank/data
  [ "$status" -eq 2 ]
  [[ "$output" == *"does not exist locally"* ]]
}

# --- Sync operations ---

@test "initial sync sends first local snapshot with zfs send and receive" {
  add_local_snap "tank/data@snap1" "1000"
  add_local_snap "tank/data@snap2" "2000"
  # No remote snapshots

  run "$SYNC" tank/data
  [ "$status" -eq 0 ]

  # The full (non-incremental) send, not just any send mentioning snap1
  grep -qx "zfs send tank/data@snap1" "$MOCK_ZFS_LOG"
  grep -q "receive backup/data" "$MOCK_REMOTE_LOG"
}

@test "first sync creates the remote filesystem when it does not exist" {
  # Regression: under set -e the failing remote zfs list aborted the script,
  # so the full-send branch that creates the remote filesystem was dead code.
  export MOCK_REMOTE_MISSING_FS=1
  add_local_snap "tank/data@snap1" "1000"
  add_local_snap "tank/data@snap2" "2000"

  run "$SYNC" tank/data
  [ "$status" -eq 0 ]
  # Not silent: the first run tells cron what it is doing
  [[ "$output" == *"assuming it does not exist yet"* ]]

  # Full send of the oldest snapshot; the receive that creates the
  # filesystem must not use -F
  grep -qx "zfs send tank/data@snap1" "$MOCK_ZFS_LOG"
  [ "$(grep "receive" "$MOCK_REMOTE_LOG" | head -1)" = "remote_zfs receive backup/data" ]
  # ...then caught up in the same run
  grep -q "zfs send -i tank/data@snap1 tank/data@snap2" "$MOCK_ZFS_LOG"
}

@test "pv gets the stream size so it can show an ETA" {
  add_local_snap "tank/data@snap1" "1000"
  add_local_snap "tank/data@snap2" "2000"
  export MOCK_ZFS_SEND_SIZE=12345

  # pv is only used on a terminal
  export PV="$TEST_TMPDIR/pv"
  printf '#!/bin/sh\necho "pv $*" >> "%s/pv.log"\ncat\n' "$TEST_TMPDIR" > "$PV"
  chmod +x "$PV"
  run script -qec "$SYNC tank/data" /dev/null
  [ "$status" -eq 0 ]

  [ "$(grep -c "^pv -s 12345$" "$TEST_TMPDIR/pv.log")" -eq 2 ]
  grep -qx "zfs send -nvP tank/data@snap1" "$MOCK_ZFS_LOG"
  grep -qx "zfs send -nvP -i tank/data@snap1 tank/data@snap2" "$MOCK_ZFS_LOG"
}

@test "initial sync sends every snapshot, not just the oldest" {
  add_local_snap "tank/data@snap1" "1000"
  add_local_snap "tank/data@snap2" "2000"
  add_local_snap "tank/data@snap3" "3000"
  # No remote snapshots -> fresh-remote / initial-sync branch

  run "$SYNC" tank/data
  [ "$status" -eq 0 ]

  # Full send of the oldest snapshot
  grep -qx "zfs send tank/data@snap1" "$MOCK_ZFS_LOG"
  grep -q "receive backup/data" "$MOCK_REMOTE_LOG"
  # Plus incremental sends to fast-forward every newer snapshot
  grep -q "zfs send -i tank/data@snap1 tank/data@snap2" "$MOCK_ZFS_LOG"
  grep -q "zfs send -i tank/data@snap2 tank/data@snap3" "$MOCK_ZFS_LOG"
  grep -q "receive -F backup/data" "$MOCK_REMOTE_LOG"
}

@test "initial sync with single local snapshot does not emit any incrementals" {
  add_local_snap "tank/data@only" "1000"
  # No remote snapshots

  run "$SYNC" tank/data
  [ "$status" -eq 0 ]

  grep -qx "zfs send tank/data@only" "$MOCK_ZFS_LOG"
  log_not_contains "$MOCK_ZFS_LOG" "send -i "
}

@test "incremental sync sends with zfs send -i and receive -F" {
  add_local_snap "tank/data@snap1" "1000"
  add_local_snap "tank/data@snap2" "2000"
  add_local_snap "tank/data@snap3" "3000"

  add_remote_snap "backup/data@snap1" "1000"

  run "$SYNC" tank/data
  [ "$status" -eq 0 ]

  grep -q "send.*-i tank/data@snap1 tank/data@snap2" "$MOCK_ZFS_LOG"
  grep -q "send.*-i tank/data@snap2 tank/data@snap3" "$MOCK_ZFS_LOG"
  grep -q "receive -F backup/data" "$MOCK_REMOTE_LOG"
}

@test "already in sync does nothing and exits 0" {
  # Use 3 snapshots so bypassing the != check would produce actual sends
  add_local_snap "tank/data@snap1" "1000"
  add_local_snap "tank/data@snap2" "2000"
  add_local_snap "tank/data@snap3" "3000"

  add_remote_snap "backup/data@snap3" "3000"

  run "$SYNC" tank/data
  [ "$status" -eq 0 ]

  # Verify the script actually ran (set the lock, listed snapshots)
  grep -Eq "set dlx.dk.sync:running=[0-9]+ tank/data" "$MOCK_ZFS_LOG"
  log_not_contains "$MOCK_ZFS_LOG" "zfs send"
  log_not_contains "$MOCK_REMOTE_LOG" "remote_zfs receive"
}

@test "sync ignores snapshots of child datasets" {
  # Regression: with a recursive list (-rH), same-named snapshots on child
  # datasets appeared twice in the plan, producing duplicate/invalid
  # incremental sends (zfs send -i @X @X).  -d 1 must exclude them.
  add_local_snap "tank/data@snap1" "1000"
  add_local_snap "tank/data/child@snap1" "1100"
  add_local_snap "tank/data@snap2" "2000"
  add_local_snap "tank/data/child@snap2" "2100"
  add_remote_snap "backup/data@snap1" "1000"

  run "$SYNC" tank/data
  [ "$status" -eq 0 ]

  grep -q "zfs send -i tank/data@snap1 tank/data@snap2" "$MOCK_ZFS_LOG"
  # Exactly one send -- child snapshots must not add duplicates
  [ "$(grep -c "zfs send" "$MOCK_ZFS_LOG")" -eq 1 ]
}

@test "falls back to recursive remote list when the receiver rejects -d 1" {
  # An older authorized_keys_commands.sh on the receiver only allows -rH.
  # The child's @snap3 is the newest remote snapshot overall; if it leaked
  # through the filter, sync.sh would abort with "snap3 does not exist locally".
  export MOCK_REMOTE_LEGACY_ONLY=1
  add_local_snap "tank/data@snap1" "1000"
  add_local_snap "tank/data@snap2" "2000"
  add_remote_snap "backup/data@snap1" "1000"
  add_remote_snap "backup/data/child@snap1" "1100"
  add_remote_snap "backup/data/child@snap3" "3000"

  run "$SYNC" tank/data
  [ "$status" -eq 0 ]
  # The fallback is expected during rollout -- stay quiet for cron
  [ -z "$output" ]

  grep -q "remote_zfs list -t snapshot -s creation -o name -rH backup/data" "$MOCK_REMOTE_LOG"
  grep -q "zfs send -i tank/data@snap1 tank/data@snap2" "$MOCK_ZFS_LOG"
  [ "$(grep -c "zfs send" "$MOCK_ZFS_LOG")" -eq 1 ]
}

@test "sendargs property is passed through to zfs send" {
  add_local_snap "tank/data@snap1" "1000"
  add_local_snap "tank/data@snap2" "2000"
  add_remote_snap "backup/data@snap1" "1000"
  export MOCK_ZFS_PROP_SENDARGS="-w"

  run "$SYNC" tank/data
  [ "$status" -eq 0 ]

  grep -q "zfs send -w -i tank/data@snap1 tank/data@snap2" "$MOCK_ZFS_LOG"
}

@test "multi-flag sendargs are passed to zfs send as separate flags" {
  add_local_snap "tank/data@snap1" "1000"
  add_local_snap "tank/data@snap2" "2000"
  add_remote_snap "backup/data@snap1" "1000"
  export MOCK_ZFS_PROP_SENDARGS="-w -c"

  run "$SYNC" tank/data
  [ "$status" -eq 0 ]

  grep -qx "zfs send -w -c -i tank/data@snap1 tank/data@snap2" "$MOCK_ZFS_LOG"
}

# --- Snapshot name ordering vs creation time ---

@test "initial sync uses oldest snapshot by creation time not by name" {
  # Names sort alphabetically as z, a, m -- but creation times are 1000, 2000, 3000
  add_local_snap "tank/data@z-first-alpha" "1000"
  add_local_snap "tank/data@a-last-alpha" "2000"
  add_local_snap "tank/data@m-mid-alpha" "3000"

  run "$SYNC" tank/data
  [ "$status" -eq 0 ]

  # Should send z-first-alpha (oldest by creation), not a-last-alpha (first alphabetically)
  grep -qx "zfs send tank/data@z-first-alpha" "$MOCK_ZFS_LOG"
}

@test "incremental sync follows creation time order not name order" {
  # Added in non-chronological order, names don't sort the same as timestamps
  add_local_snap "tank/data@snap-charlie" "3000"
  add_local_snap "tank/data@snap-alpha" "1000"
  add_local_snap "tank/data@snap-bravo" "2000"

  add_remote_snap "backup/data@snap-alpha" "1000"

  run "$SYNC" tank/data
  [ "$status" -eq 0 ]

  # Mock sorts by creation time, so order should be: alpha(1000) -> bravo(2000) -> charlie(3000)
  grep -q "send.*-i tank/data@snap-alpha tank/data@snap-bravo" "$MOCK_ZFS_LOG"
  grep -q "send.*-i tank/data@snap-bravo tank/data@snap-charlie" "$MOCK_ZFS_LOG"
}

@test "already in sync detected by creation time not name" {
  # Newest by creation time is snap-alpha (3000), not snap-zulu (1000)
  # 3 snapshots so bypassing != check would produce sends
  add_local_snap "tank/data@snap-zulu" "1000"
  add_local_snap "tank/data@snap-mike" "2000"
  add_local_snap "tank/data@snap-alpha" "3000"

  # Remote has snap-alpha -- should be considered in sync
  add_remote_snap "backup/data@snap-alpha" "3000"

  run "$SYNC" tank/data
  [ "$status" -eq 0 ]

  # Verify the script actually ran
  grep -Eq "set dlx.dk.sync:running=[0-9]+ tank/data" "$MOCK_ZFS_LOG"
  log_not_contains "$MOCK_ZFS_LOG" "zfs send"
  log_not_contains "$MOCK_REMOTE_LOG" "remote_zfs receive"
}

# --- Running lock lifecycle ---

@test "sets running lock before sync and clears it after" {
  add_local_snap "tank/data@snap1" "1000"
  add_local_snap "tank/data@snap2" "2000"

  add_remote_snap "backup/data@snap2" "2000"

  run "$SYNC" tank/data
  [ "$status" -eq 0 ]

  grep -Eq "set dlx.dk.sync:running=[0-9]+ tank/data" "$MOCK_ZFS_LOG"
  grep -q "inherit dlx.dk.sync:running tank/data" "$MOCK_ZFS_LOG"
}

# --- Pipeline failure handling ---
# Regression coverage: under POSIX `sh`, `zfs send | zfs receive || exit 2` only
# catches a receive failure -- a failing zfs send is silently masked.  sync.sh
# re-execs under bash with `set -o pipefail` so the send failure propagates.

@test "initial sync exits 2 when zfs send fails mid-pipeline" {
  add_local_snap "tank/data@snap1" "1000"
  add_local_snap "tank/data@snap2" "2000"
  # No remote snapshots -> initial-sync branch
  export MOCK_ZFS_SEND_FAIL=1

  run "$SYNC" tank/data
  [ "$status" -eq 2 ]
}

@test "incremental sync exits 2 when zfs send fails mid-pipeline" {
  add_local_snap "tank/data@snap1" "1000"
  add_local_snap "tank/data@snap2" "2000"
  add_local_snap "tank/data@snap3" "3000"
  add_remote_snap "backup/data@snap1" "1000"
  export MOCK_ZFS_SEND_FAIL=1

  run "$SYNC" tank/data
  [ "$status" -eq 2 ]
}
