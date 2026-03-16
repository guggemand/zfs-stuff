#!/bin/bash
#
# Common test helper for cleansnap.sh tests
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOCK_DIR="$SCRIPT_DIR/test/mocks"
CLEANSNAP="$SCRIPT_DIR/cleansnap.sh"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  export MOCK_ZFS_LOG="$TEST_TMPDIR/zfs.log"
  export MOCK_ZFS_SNAPSHOTS="$TEST_TMPDIR/snapshots.txt"
  export MOCK_ZFS_VALID_FS="tank/data"
  export ZFS="$MOCK_DIR/zfs"
  export DATE="$MOCK_DIR/date"
  export BASH=/bin/bash
  export FAKE_NOW="2025-01-15 12:00:00"
  touch "$MOCK_ZFS_LOG"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# Helper: create a snapshot entry in the mock data
# Usage: add_snap "tank/data@snap-20250101-120000" 1735732800
add_snap() {
  printf '%s\t%s\n' "$1" "$2" >> "$MOCK_ZFS_SNAPSHOTS"
}

# Helper: create a bookmark entry in the mock data
# Usage: add_bookmark "tank/data#snap-20250101-120000" 1735732800
add_bookmark() {
  printf '%s\t%s\n' "$1" "$2" >> "$MOCK_ZFS_SNAPSHOTS"
}

# Helper: count how many "zfs destroy" calls were logged
destroy_count() {
  grep -c "^zfs destroy" "$MOCK_ZFS_LOG" || echo 0
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
