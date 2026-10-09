#!/usr/bin/env bats

#
# Tests for snapandsync.sh
#
# Strategy: like syncall.bats -- copy snapandsync.sh into a temp directory
# next to mock snap.sh and sync.sh scripts, since it locates them via
# `dirname "$0"`.
#

load test_helper

setup() {
  common_setup
  use_mock_zfs

  export MOCK_CALL_LOG="$TEST_TMPDIR/calls.log"
  touch "$MOCK_CALL_LOG"

  cat > "$TEST_TMPDIR/snap.sh" <<'MOCK'
#!/bin/sh
echo "snap $1" >> "$MOCK_CALL_LOG"
exit "${MOCK_SNAP_EXIT:-0}"
MOCK

  cat > "$TEST_TMPDIR/sync.sh" <<'MOCK'
#!/bin/sh
echo "sync $1" >> "$MOCK_CALL_LOG"
exit "${MOCK_SYNC_EXIT:-0}"
MOCK

  chmod +x "$TEST_TMPDIR/snap.sh" "$TEST_TMPDIR/sync.sh"

  cp "$SNAPANDSYNC" "$TEST_TMPDIR/snapandsync.sh"
  chmod +x "$TEST_TMPDIR/snapandsync.sh"
}

teardown() {
  common_teardown
}

@test "exits with error when no arguments given" {
  run "$TEST_TMPDIR/snapandsync.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "exits with error for invalid filesystem" {
  export MOCK_ZFS_VALID_FS="tank/other"
  run "$TEST_TMPDIR/snapandsync.sh" tank/data
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid FileSystem"* ]]
  log_not_contains "$MOCK_CALL_LOG" "snap"
}

@test "runs snap.sh then sync.sh with the filesystem" {
  run "$TEST_TMPDIR/snapandsync.sh" tank/data
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_CALL_LOG")" = "snap tank/data
sync tank/data" ]
}

@test "does not run sync.sh when snap.sh fails" {
  export MOCK_SNAP_EXIT=1
  run "$TEST_TMPDIR/snapandsync.sh" tank/data
  [ "$status" -ne 0 ]
  grep -q "snap tank/data" "$MOCK_CALL_LOG"
  log_not_contains "$MOCK_CALL_LOG" "sync"
}
