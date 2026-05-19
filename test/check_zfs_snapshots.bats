#!/usr/bin/env bats

load test_helper

setup() {
  common_setup
  use_mock_zfs

  # check_zfs_snapshots.sh calls `date +%s` directly; install a minimal mock
  # on PATH that returns a fixed epoch.
  FAKE_NOW_EPOCH=$($(command -v gdate || command -v date) -d "2025-01-15 12:00:00" +%s)
  export FAKE_NOW_EPOCH
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/date" << 'MOCK'
#!/bin/sh
if [ "$1" = "+%s" ]; then
  echo "$FAKE_NOW_EPOCH"
else
  $(command -v gdate || command -v date) "$@"
fi
MOCK
  chmod +x "$TEST_TMPDIR/bin/date"
  export PATH="$TEST_TMPDIR/bin:$PATH"
}

teardown() {
  common_teardown
}

# --- Argument validation ---

@test "exits with error when no arguments given" {
  run "$CHECK_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "exits with error when only threshold given" {
  run "$CHECK_SCRIPT" 60
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

# --- OK states ---

@test "exits 0 when snapshot is within threshold" {
  SNAP_TIME=$(( FAKE_NOW_EPOCH - 600 ))
  add_snap "tank/data@snap-recent" "$SNAP_TIME"

  run "$CHECK_SCRIPT" 60 tank/data
  [ "$status" -eq 0 ]
  [[ "$output" == "OK:"* ]]
}

@test "outputs OK message with perfdata" {
  SNAP_TIME=$(( FAKE_NOW_EPOCH - 600 ))
  add_snap "tank/data@snap-recent" "$SNAP_TIME"

  run "$CHECK_SCRIPT" 60 tank/data
  [ "$status" -eq 0 ]
  [[ "$output" == "OK:"* ]]
  [[ "$output" == *"| tank/data="* ]]
}

# --- CRITICAL states ---

@test "exits 2 when snapshot is older than threshold" {
  SNAP_TIME=$(( FAKE_NOW_EPOCH - 7200 ))
  add_snap "tank/data@snap-old" "$SNAP_TIME"

  run "$CHECK_SCRIPT" 60 tank/data
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR:"* ]]
}

@test "exits 2 when filesystem does not exist" {
  run "$CHECK_SCRIPT" 60 tank/missing
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR: tank/missing does not exist"* ]]
}

@test "error output includes the stale snapshot name" {
  SNAP_TIME=$(( FAKE_NOW_EPOCH - 7200 ))
  add_snap "tank/data@snap-stale" "$SNAP_TIME"

  run "$CHECK_SCRIPT" 60 tank/data
  [ "$status" -eq 2 ]
  [[ "$output" == *"snap-stale"* ]]
}

# --- Per-filesystem threshold ---

@test "per-filesystem threshold overrides default" {
  # Snapshot 45 minutes ago. Default 60min = OK. Per-fs 30min = CRITICAL.
  SNAP_TIME=$(( FAKE_NOW_EPOCH - 2700 ))
  add_snap "tank/data@snap-mid" "$SNAP_TIME"

  run "$CHECK_SCRIPT" 60 tank/data:30
  [ "$status" -eq 2 ]
}

@test "per-filesystem threshold allows longer window" {
  # Snapshot 90 minutes ago. Default 60min = CRITICAL. Per-fs 120min = OK.
  SNAP_TIME=$(( FAKE_NOW_EPOCH - 5400 ))
  add_snap "tank/data@snap-ok" "$SNAP_TIME"

  run "$CHECK_SCRIPT" 60 tank/data:120
  [ "$status" -eq 0 ]
  [[ "$output" == "OK:"* ]]
}

# --- Multiple filesystems ---

@test "OK when all filesystems are within threshold" {
  T1=$(( FAKE_NOW_EPOCH - 600 ))
  T2=$(( FAKE_NOW_EPOCH - 300 ))
  add_snap "tank/data@snap-1" "$T1"
  add_snap "tank/logs@snap-1" "$T2"

  run "$CHECK_SCRIPT" 60 tank/data tank/logs
  [ "$status" -eq 0 ]
  [[ "$output" == "OK:"* ]]
}

@test "CRITICAL when one filesystem exceeds threshold" {
  T_OK=$(( FAKE_NOW_EPOCH - 600 ))
  T_OLD=$(( FAKE_NOW_EPOCH - 7200 ))
  add_snap "tank/data@snap-1" "$T_OK"
  add_snap "tank/logs@snap-1" "$T_OLD"

  run "$CHECK_SCRIPT" 60 tank/data tank/logs
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR:"* ]]
  # Verify the stale filesystem is flagged, not the fresh one
  [[ "$output" == *"tank/logs@"* ]]
}

@test "mixed per-filesystem thresholds" {
  # tank/data: 10 min old, default 60 → OK
  # tank/logs: 45 min old, override 30 → CRITICAL
  T1=$(( FAKE_NOW_EPOCH - 600 ))
  T2=$(( FAKE_NOW_EPOCH - 2700 ))
  add_snap "tank/data@snap-1" "$T1"
  add_snap "tank/logs@snap-1" "$T2"

  run "$CHECK_SCRIPT" 60 tank/data tank/logs:30
  [ "$status" -eq 2 ]
}

# --- Perfdata format ---

@test "perfdata contains all filesystems" {
  T1=$(( FAKE_NOW_EPOCH - 600 ))
  T2=$(( FAKE_NOW_EPOCH - 300 ))
  add_snap "tank/data@snap-1" "$T1"
  add_snap "tank/logs@snap-1" "$T2"

  run "$CHECK_SCRIPT" 60 tank/data tank/logs
  [ "$status" -eq 0 ]
  [[ "$output" == *"tank/data="* ]]
  [[ "$output" == *"tank/logs="* ]]
}

@test "perfdata includes threshold value" {
  SNAP_TIME=$(( FAKE_NOW_EPOCH - 600 ))
  add_snap "tank/data@snap-1" "$SNAP_TIME"

  run "$CHECK_SCRIPT" 60 tank/data
  [ "$status" -eq 0 ]
  # Perfdata format: fs=value;;threshold (threshold = 60*60 = 3600 seconds)
  [[ "$output" == *";;3600"* ]]
}

@test "perfdata uses per-filesystem threshold when set" {
  SNAP_TIME=$(( FAKE_NOW_EPOCH - 600 ))
  add_snap "tank/data@snap-1" "$SNAP_TIME"

  run "$CHECK_SCRIPT" 60 tank/data:30
  [ "$status" -eq 0 ]
  # Per-fs threshold = 30 min = 1800 seconds
  [[ "$output" == *";;1800"* ]]
}

# --- Multiple snapshots per filesystem ---

@test "uses newest snapshot for comparison" {
  T_OLD=$(( FAKE_NOW_EPOCH - 7200 ))
  T_NEW=$(( FAKE_NOW_EPOCH - 600 ))
  add_snap "tank/data@snap-old" "$T_OLD"
  add_snap "tank/data@snap-new" "$T_NEW"

  run "$CHECK_SCRIPT" 60 tank/data
  [ "$status" -eq 0 ]
  [[ "$output" == "OK:"* ]]
}

@test "uses creation time not name to find newest snapshot" {
  # snap-alpha is alphabetically first but newest by creation time (10 min ago)
  # snap-zebra is alphabetically last but oldest by creation time (2 hours ago)
  T_OLD=$(( FAKE_NOW_EPOCH - 7200 ))
  T_NEW=$(( FAKE_NOW_EPOCH - 600 ))
  add_snap "tank/data@snap-zebra" "$T_OLD"
  add_snap "tank/data@snap-alpha" "$T_NEW"

  # Threshold 60 min. snap-alpha (10 min) is newest by creation → OK
  # If sorted by name, snap-zebra (2h old) would be "newest" → CRITICAL
  run "$CHECK_SCRIPT" 60 tank/data
  [ "$status" -eq 0 ]
  [[ "$output" == "OK:"* ]]
}
