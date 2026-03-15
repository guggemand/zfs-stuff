#!/usr/bin/env bats

setup() {
  SYNC="$BATS_TEST_DIRNAME/../sync.sh"
  MOCK_DIR="$BATS_TEST_DIRNAME/mocks"
  TEST_TMPDIR=$(mktemp -d)

  export MOCK_ZFS_LOG="$TEST_TMPDIR/local.log"
  export MOCK_REMOTE_LOG="$TEST_TMPDIR/remote.log"
  touch "$MOCK_ZFS_LOG" "$MOCK_REMOTE_LOG"

  # Local mock uses shared mocks/zfs
  export LOCALCMD="$MOCK_DIR/zfs"
  export MOCK_ZFS_VALID_FS="tank/data"
  export MOCK_ZFS_SNAPSHOTS="$TEST_TMPDIR/snapshots.txt"
  touch "$MOCK_ZFS_SNAPSHOTS"

  # Per-property defaults for sync.sh
  export MOCK_ZFS_PROP_REMOTECMD="$TEST_TMPDIR/remote_zfs"
  export MOCK_ZFS_PROP_REMOTEFS="backup/data"
  export MOCK_ZFS_PROP_SENDARGS="-"
  export MOCK_ZFS_PROP_RUNNING="-"

  # Remote mock -- uses its own snapshot file and log
  export MOCK_REMOTE_SNAPSHOTS="$TEST_TMPDIR/remote_snapshots.txt"
  touch "$MOCK_REMOTE_SNAPSHOTS"
  cat > "$TEST_TMPDIR/remote_zfs" <<'MOCK'
#!/bin/sh
echo "remote_zfs $*" >> "$MOCK_REMOTE_LOG"
case "$1" in
  list)
    if [ -f "$MOCK_REMOTE_SNAPSHOTS" ]; then
      sort -t'	' -k2 -n "$MOCK_REMOTE_SNAPSHOTS" | cut -f1
    fi
    exit 0 ;;
  receive)
    cat > /dev/null
    exit 0 ;;
esac
echo "mock remote_zfs: unhandled: $*" >&2
exit 1
MOCK
  chmod +x "$TEST_TMPDIR/remote_zfs"

  export PV="/nonexistent/pv"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# Helper: add a local snapshot (name + epoch)
add_local_snap() {
  printf '%s\t%s\n' "$1" "$2" >> "$MOCK_ZFS_SNAPSHOTS"
}

# Helper: add a remote snapshot (name + epoch)
add_remote_snap() {
  printf '%s\t%s\n' "$1" "$2" >> "$MOCK_REMOTE_SNAPSHOTS"
}

local_log_contains() {
  grep -q "$1" "$MOCK_ZFS_LOG"
}

remote_log_contains() {
  grep -q "$1" "$MOCK_REMOTE_LOG"
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

@test "exits 2 when sync is already running" {
  export MOCK_ZFS_PROP_RUNNING="1"
  run "$SYNC" tank/data
  [ "$status" -eq 2 ]
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

  local_log_contains "send.*tank/data@snap1"
  remote_log_contains "receive backup/data"
}

@test "incremental sync sends with zfs send -i and receive -F" {
  add_local_snap "tank/data@snap1" "1000"
  add_local_snap "tank/data@snap2" "2000"
  add_local_snap "tank/data@snap3" "3000"

  add_remote_snap "backup/data@snap1" "1000"

  run "$SYNC" tank/data
  [ "$status" -eq 0 ]

  local_log_contains "send.*-i tank/data@snap1 tank/data@snap2"
  local_log_contains "send.*-i tank/data@snap2 tank/data@snap3"
  remote_log_contains "receive -F backup/data"
}

@test "already in sync does nothing and exits 0" {
  add_local_snap "tank/data@snap1" "1000"
  add_local_snap "tank/data@snap2" "2000"

  add_remote_snap "backup/data@snap2" "2000"

  run "$SYNC" tank/data
  [ "$status" -eq 0 ]

  ! local_log_contains "send"
  ! remote_log_contains "receive"
}

# --- Running lock lifecycle ---

@test "sets running lock before sync and clears it after" {
  add_local_snap "tank/data@snap1" "1000"
  add_local_snap "tank/data@snap2" "2000"

  add_remote_snap "backup/data@snap2" "2000"

  run "$SYNC" tank/data
  [ "$status" -eq 0 ]

  local_log_contains "set dlx.dk.sync:running=1 tank/data"
  local_log_contains "inherit dlx.dk.sync:running tank/data"
}
