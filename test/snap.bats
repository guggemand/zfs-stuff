#!/usr/bin/env bats

load test_helper

setup() {
  common_setup
  use_mock_zfs
  use_mock_date
  export MOCK_ZFS_ACCEPT_ALL=1
}

teardown() {
  common_teardown
}

@test "exits with error when no arguments given" {
  run "$SNAP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "exits with error for invalid filesystem" {
  unset MOCK_ZFS_ACCEPT_ALL
  export MOCK_ZFS_VALID_FS="tank/other"
  run "$SNAP" tank/data
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid FileSystem"* ]]
}

@test "creates snapshot with correct naming format" {
  run "$SNAP" tank/data
  [ "$status" -eq 0 ]
  grep -q 'zfs snapshot tank/data@snap-20250115-120000' "$MOCK_ZFS_LOG"
}

@test "passes the correct filesystem to zfs snapshot command" {
  export MOCK_ZFS_VALID_FS="tank/other"
  run "$SNAP" tank/other
  [ "$status" -eq 0 ]
  grep -q 'zfs snapshot tank/other@snap-' "$MOCK_ZFS_LOG"
}

@test "snapshot timestamp comes from the DATE command" {
  export FAKE_NOW="2024-06-30 08:45:59"
  run "$SNAP" tank/data
  [ "$status" -eq 0 ]
  grep -q 'zfs snapshot tank/data@snap-20240630-084559' "$MOCK_ZFS_LOG"
}
