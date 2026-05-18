#!/bin/bash
#
# Shared helper for all .bats test files.
#
# Usage in a test file:
#   load test_helper
#   setup()    { common_setup; use_mock_zfs; use_mock_date; ... }
#   teardown() { common_teardown; }
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOCK_DIR="$SCRIPT_DIR/test/mocks"
CLEANSNAP="$SCRIPT_DIR/cleansnap.sh"

# Create a per-test tmpdir and initialise the mock zfs log.
common_setup() {
  TEST_TMPDIR=$(mktemp -d)
  export TEST_TMPDIR
  export MOCK_ZFS_LOG="$TEST_TMPDIR/zfs.log"
  touch "$MOCK_ZFS_LOG"
}

common_teardown() {
  rm -rf "$TEST_TMPDIR"
}

# Point $ZFS at the shared mocks/zfs script.
# add_snap/add_bookmark create $MOCK_ZFS_SNAPSHOTS on demand; we deliberately do
# NOT touch it here so tests that exercise the "no snapshots" path see the mock
# fall through to its error case.
use_mock_zfs() {
  export ZFS="$MOCK_DIR/zfs"
  export MOCK_ZFS_SNAPSHOTS="$TEST_TMPDIR/snapshots.txt"
  export MOCK_ZFS_VALID_FS="${MOCK_ZFS_VALID_FS:-tank/data}"
}

# Point $DATE at the shared mocks/date script.
use_mock_date() {
  export DATE="$MOCK_DIR/date"
  export BASH=$(command -v bash)
  export FAKE_NOW="${FAKE_NOW:-2025-01-15 12:00:00}"
}

# Append a snapshot entry (tab-separated name<TAB>creation_epoch) to the mock data.
# Usage: add_snap "tank/data@snap-20250101-120000" 1735732800
add_snap() {
  printf '%s\t%s\n' "$1" "$2" >> "$MOCK_ZFS_SNAPSHOTS"
}

# Append a bookmark entry.  Same shape as a snapshot but the name uses '#'.
# Usage: add_bookmark "tank/data#snap-20250101-120000" 1735732800
add_bookmark() {
  printf '%s\t%s\n' "$1" "$2" >> "$MOCK_ZFS_SNAPSHOTS"
}

# Helper: check if a specific snapshot was destroyed
was_destroyed() {
  grep -q "zfs destroy.*$1" "$MOCK_ZFS_LOG"
}

# Helper: assert a snapshot was NOT destroyed
# NOTE: Do not use "! was_destroyed" -- the ! prefix suppresses errexit in bash,
# so the assertion silently passes even when it should fail.
was_not_destroyed() {
  if grep -q "zfs destroy.*$1" "$MOCK_ZFS_LOG"; then
    echo "Expected $1 to NOT be destroyed, but it was" >&2
    return 1
  fi
}

# Helper: check if a snapshot was destroyed with the -d (deferred) flag
was_destroyed_deferred() {
  grep -q "zfs destroy -d.*$1" "$MOCK_ZFS_LOG"
}

# Helper: check if a snapshot was destroyed without -d (immediate, used for bookmarks)
was_destroyed_immediate() {
  grep "zfs destroy " "$MOCK_ZFS_LOG" | grep -v "zfs destroy -d" | grep -q "$1"
}

# Helper: check if a bookmark was created for a snapshot
was_bookmarked() {
  grep -q "zfs bookmark.*$1" "$MOCK_ZFS_LOG"
}

# Helper: assert cleansnap actually ran (zfs commands appear in log)
cleansnap_ran() {
  if ! grep -q "zfs list" "$MOCK_ZFS_LOG"; then
    echo "cleansnap.sh did not run -- no zfs commands in log" >&2
    return 1
  fi
}

# Helper: generate epoch for a date, with optional day offset
# Usage: epoch "2025-01-15 06:00:00"
#        epoch_offset "2025-01-15" -3   (3 days earlier)
epoch() {
  $(command -v gdate || command -v date) -d "$1" +%s
}

epoch_offset() {
  local base="$1"
  local days="$2"
  # Use "X days ago" syntax -- negative offset becomes positive "ago"
  local abs_days=${days#-}
  $(command -v gdate || command -v date) -d "$base ${abs_days} days ago" +%s
}
