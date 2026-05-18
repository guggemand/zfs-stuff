#!/usr/bin/env bats

#
# Tests for syncall.sh
#
# Strategy: copy syncall.sh into a temp directory alongside a mock sync.sh,
# since syncall.sh uses `dirname "$0"` to locate sync.sh.  A per-test mock
# zfs script in the same temp directory handles the `get` command and returns
# a configurable filesystem list.
#

load test_helper

setup() {
  common_setup

  # --- mock zfs -----------------------------------------------------------
  # Returns filesystems listed in $MOCK_ZFS_FILESYSTEMS (one per line).
  # Falls through to exit 0 for unrecognised commands.
  cat > "$TEST_TMPDIR/zfs" <<'MOCK'
#!/bin/sh
if [ -n "$MOCK_ZFS_LOG" ]; then
  echo "zfs $*" >> "$MOCK_ZFS_LOG"
fi
case "$1" in
  get)
    if [ -n "$MOCK_ZFS_FILESYSTEMS" ] && [ -f "$MOCK_ZFS_FILESYSTEMS" ]; then
      cat "$MOCK_ZFS_FILESYSTEMS"
    fi
    exit 0
    ;;
esac
exit 0
MOCK
  chmod +x "$TEST_TMPDIR/zfs"

  # --- mock sync.sh -------------------------------------------------------
  # Logs the filesystem it was called with.  Exits with the status found in
  # MOCK_SYNC_EXIT_STATUS_<sanitised_fs> (slashes replaced with underscores),
  # or 0 if unset.
  cat > "$TEST_TMPDIR/sync.sh" <<'MOCK'
#!/bin/sh
echo "$1" >> "$MOCK_SYNC_LOG"
# Derive the variable name from the filesystem argument (/ -> _)
VARNAME="MOCK_SYNC_EXIT_$(echo "$1" | tr '/' '_')"
eval "STATUS=\${$VARNAME:-0}"
exit "$STATUS"
MOCK
  chmod +x "$TEST_TMPDIR/sync.sh"

  # --- copy the script under test -----------------------------------------
  cp "$SYNCALL" "$TEST_TMPDIR/syncall.sh"
  chmod +x "$TEST_TMPDIR/syncall.sh"

  # --- environment --------------------------------------------------------
  export ZFS="$TEST_TMPDIR/zfs"
  export MOCK_ZFS_FILESYSTEMS="$TEST_TMPDIR/filesystems.txt"
  export MOCK_SYNC_LOG="$TEST_TMPDIR/sync.log"

  touch "$MOCK_ZFS_FILESYSTEMS"
  touch "$MOCK_SYNC_LOG"
}

teardown() {
  common_teardown
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Was sync.sh called with the given filesystem?
was_synced() {
  grep -qx "$1" "$MOCK_SYNC_LOG"
}

# How many times was sync.sh called?
sync_count() {
  if [ -s "$MOCK_SYNC_LOG" ]; then
    wc -l < "$MOCK_SYNC_LOG" | tr -d ' '
  else
    echo 0
  fi
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# --- ZFS binary check ---

@test "exits with error when ZFS binary is missing" {
  export ZFS="/nonexistent/path/to/zfs"
  run "$TEST_TMPDIR/syncall.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"zfs binary is missing"* ]]
}

# --- Runs sync.sh for each filesystem ---

@test "runs sync.sh for each filesystem returned by zfs get" {
  printf '%s\n' "tank/data" "tank/backup" "rpool/home" > "$MOCK_ZFS_FILESYSTEMS"

  run "$TEST_TMPDIR/syncall.sh"
  [ "$status" -eq 0 ]

  was_synced "tank/data"
  was_synced "tank/backup"
  was_synced "rpool/home"
  [ "$(sync_count)" -eq 3 ]
}

# --- All syncs succeed ---

@test "exits 0 when all syncs succeed" {
  printf '%s\n' "tank/a" "tank/b" > "$MOCK_ZFS_FILESYSTEMS"

  run "$TEST_TMPDIR/syncall.sh"
  [ "$status" -eq 0 ]
  # Verify sync.sh was actually called
  [ "$(sync_count)" -eq 2 ]
}

# --- A sync fails but remaining filesystems still run ---

@test "exits non-zero when a sync fails but continues syncing remaining filesystems" {
  printf '%s\n' "tank/first" "tank/fail" "tank/last" > "$MOCK_ZFS_FILESYSTEMS"

  # Make sync.sh fail for tank/fail
  export MOCK_SYNC_EXIT_tank_fail=1

  run "$TEST_TMPDIR/syncall.sh"
  [ "$status" -ne 0 ]

  # All three must have been attempted
  was_synced "tank/first"
  was_synced "tank/fail"
  was_synced "tank/last"
  [ "$(sync_count)" -eq 3 ]
}

# --- Empty filesystem list ---

@test "exits 0 when no filesystems are returned" {
  # MOCK_ZFS_FILESYSTEMS is empty (created in setup)
  run "$TEST_TMPDIR/syncall.sh"
  [ "$status" -eq 0 ]
  [ "$(sync_count)" -eq 0 ]
  # Verify the script ran (called zfs get)
  grep -q "zfs get" "$MOCK_ZFS_LOG"
}

# --- Correct zfs get invocation ---

@test "calls zfs get with correct arguments" {
  run "$TEST_TMPDIR/syncall.sh"
  [ "$status" -eq 0 ]
  grep -q "zfs get -s local -t filesystem,volume -o name -H dlx.dk.sync:remotefs" "$MOCK_ZFS_LOG"
}

# --- Exit code reflects last failure ---

@test "exit code reflects the last non-zero sync exit status" {
  printf '%s\n' "tank/a" "tank/b" > "$MOCK_ZFS_FILESYSTEMS"

  export MOCK_SYNC_EXIT_tank_a=3
  # tank/b succeeds (exit 0)

  run "$TEST_TMPDIR/syncall.sh"
  # RC is set to 3 by tank/a, then overwritten to 0 by tank/b's success?
  # Re-read the script: `$DIR/sync.sh "$fs" || RC=$?`
  # || RC=$? only runs when sync.sh fails, so RC stays at 3
  [ "$status" -eq 3 ]
}
