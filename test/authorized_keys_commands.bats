#!/usr/bin/env bats

load test_helper

setup() {
  common_setup
  export PATH="$MOCK_DIR:$PATH"
  export MOCK_ZFS_ACCEPT_ALL=1
}

teardown() {
  common_teardown
}

# --- Allowed: list ---

@test "allows zfs list with correct arguments" {
  export SSH_ORIGINAL_COMMAND="zfs list -t snapshot -s creation -o name -d 1 -H tank/data"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "zfs list -t snapshot -s creation -o name -d 1 -H tank/data" "$MOCK_ZFS_LOG"
}

@test "allows legacy recursive zfs list during rollout" {
  export SSH_ORIGINAL_COMMAND="zfs list -t snapshot -s creation -o name -rH tank/data"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "zfs list -t snapshot -s creation -o name -rH tank/data" "$MOCK_ZFS_LOG"
}

@test "only accepts /sbin/zfs or zfs as command" {
  export SSH_ORIGINAL_COMMAND="/usr/bin/zfs list -t snapshot -s creation -o name -rH tank/data"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed"* ]]
}

# --- Allowed: receive ---

@test "allows zfs receive with filesystem" {
  export SSH_ORIGINAL_COMMAND="zfs receive tank/backup"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "zfs receive tank/backup" "$MOCK_ZFS_LOG"
}

@test "allows zfs receive -F with filesystem" {
  export SSH_ORIGINAL_COMMAND="zfs receive -F tank/backup"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "zfs receive -F tank/backup" "$MOCK_ZFS_LOG"
}

# --- Allowed: pigz prefix ---

@test "allows pigz prefix with zfs receive" {
  export SSH_ORIGINAL_COMMAND="pigz -d | zfs receive tank/backup"
  run "$AUTH_SCRIPT" </dev/null
  [ "$status" -eq 0 ]
  grep -q "zfs receive" "$MOCK_ZFS_LOG"
}

@test "allows pigz prefix with zfs receive -F" {
  export SSH_ORIGINAL_COMMAND="pigz -d | zfs receive -F tank/backup"
  run "$AUTH_SCRIPT" </dev/null
  [ "$status" -eq 0 ]
  grep -q "zfs receive -F" "$MOCK_ZFS_LOG"
}

@test "denies pigz prefix with zfs list" {
  # sendwithpigz.sh only wraps the receive stream in pigz, never a list
  export SSH_ORIGINAL_COMMAND="pigz -d | zfs list -t snapshot -s creation -o name -rH tank/data"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed"* ]]
  log_not_contains "$MOCK_ZFS_LOG" "zfs list"
}

@test "runs /sbin/zfs when the sender asks for /sbin/zfs" {
  # sendwithpigz.sh sends "/sbin/zfs ...".  The test host has no /sbin/zfs
  # (exit 127) or a real one, which fails on tank/data -- either way the
  # command must be accepted and executed, not denied.  The wrapper keeps
  # bats from warning about exit 127 (BW01) without pinning an exit code.
  export SSH_ORIGINAL_COMMAND="/sbin/zfs list -t snapshot -s creation -o name -d 1 -H tank/data"
  run sh -c '"$1" || true' sh "$AUTH_SCRIPT"
  [[ "$output" != *"not allowed"* ]]
}

# --- Receive target restriction (optional script argument) ---

@test "receive into the allowed filesystem is allowed when restricted" {
  export SSH_ORIGINAL_COMMAND="zfs receive -F backup/data"
  run "$AUTH_SCRIPT" backup/data
  [ "$status" -eq 0 ]
  grep -q "zfs receive -F backup/data" "$MOCK_ZFS_LOG"
}

@test "receive into a descendant of the allowed filesystem is allowed" {
  export SSH_ORIGINAL_COMMAND="zfs receive backup/data/child"
  run "$AUTH_SCRIPT" backup/data
  [ "$status" -eq 0 ]
  grep -q "zfs receive backup/data/child" "$MOCK_ZFS_LOG"
}

@test "receive outside the allowed filesystem is denied" {
  export SSH_ORIGINAL_COMMAND="zfs receive -F backup/other"
  run "$AUTH_SCRIPT" backup/data
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed"* ]]
  log_not_contains "$MOCK_ZFS_LOG" "zfs receive"
}

@test "receive restriction matches on dataset boundary not string prefix" {
  export SSH_ORIGINAL_COMMAND="zfs receive backup/database"
  run "$AUTH_SCRIPT" backup/data
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed"* ]]
  log_not_contains "$MOCK_ZFS_LOG" "zfs receive"
}

# --- Denied: wrong zfs subcommands ---

@test "denies zfs destroy" {
  export SSH_ORIGINAL_COMMAND="zfs destroy tank/data@snap"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed"* ]]
}

@test "denies zfs send" {
  export SSH_ORIGINAL_COMMAND="zfs send tank/data@snap"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed"* ]]
}

@test "denies zfs set" {
  export SSH_ORIGINAL_COMMAND="zfs set compression=lz4 tank/data"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed"* ]]
}

@test "denies zfs rollback" {
  export SSH_ORIGINAL_COMMAND="zfs rollback tank/data@snap"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed"* ]]
}

@test "denies zfs create" {
  export SSH_ORIGINAL_COMMAND="zfs create tank/evil"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed"* ]]
}

# --- Denied: wrong list arguments ---

@test "denies zfs list with wrong flags" {
  export SSH_ORIGINAL_COMMAND="zfs list -t snapshot -s creation -o name tank/data"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed"* ]]
}

@test "denies zfs list without -rH" {
  export SSH_ORIGINAL_COMMAND="zfs list -t snapshot -s creation -o name -r tank/data"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed"* ]]
}

# --- Denied: non-zfs commands ---

@test "denies arbitrary commands" {
  export SSH_ORIGINAL_COMMAND="rm -rf /"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed"* ]]
}

@test "denies shell commands" {
  export SSH_ORIGINAL_COMMAND="bash -c 'echo pwned'"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed"* ]]
}

@test "denies empty command" {
  export SSH_ORIGINAL_COMMAND=""
  run "$AUTH_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed"* ]]
}

# --- Command injection safety ---
#
# Anything beyond the exact allowed forms is rejected outright -- extra
# arguments are not silently dropped.

@test "semicolon in filesystem name is rejected" {
  # No spaces, so the command shape is valid -- only the character check
  # on the dataset name stops it
  export SSH_ORIGINAL_COMMAND="zfs receive tank/data;reboot"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed"* ]]
  log_not_contains "$MOCK_ZFS_LOG" "zfs"
}

@test "command appended after a space is rejected" {
  export SSH_ORIGINAL_COMMAND="zfs receive tank/data; rm -rf /"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed"* ]]
  log_not_contains "$MOCK_ZFS_LOG" "zfs"
}

@test "trailing pipe injection after list is rejected" {
  export SSH_ORIGINAL_COMMAND="zfs list -t snapshot -s creation -o name -rH tank/data | cat /etc/passwd"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed"* ]]
  log_not_contains "$MOCK_ZFS_LOG" "zfs"
}

@test "extra flags before the filesystem are rejected" {
  export SSH_ORIGINAL_COMMAND="zfs list -t snapshot -s creation -o name -rH -t all tank/data"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed"* ]]
  log_not_contains "$MOCK_ZFS_LOG" "zfs"
}

@test "glob characters in filesystem name are rejected" {
  export SSH_ORIGINAL_COMMAND="zfs receive tank/*"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed"* ]]
  log_not_contains "$MOCK_ZFS_LOG" "zfs"
}

@test "allows snapshot name with @" {
  export SSH_ORIGINAL_COMMAND="zfs receive tank/data@snap-1"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "zfs receive tank/data@snap-1" "$MOCK_ZFS_LOG"
}

@test "denies an empty filesystem argument" {
  export SSH_ORIGINAL_COMMAND="zfs receive "
  run "$AUTH_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed"* ]]
  log_not_contains "$MOCK_ZFS_LOG" "zfs"
}

# --- --allow-send option ---

@test "allows full send of a snapshot with --allow-send" {
  export SSH_ORIGINAL_COMMAND="zfs send tank/data@snap1"
  run "$AUTH_SCRIPT" --allow-send tank/data
  [ "$status" -eq 0 ]
  grep -qx "zfs send tank/data@snap1" "$MOCK_ZFS_LOG"
}

@test "allows incremental send -i between snapshots with --allow-send" {
  export SSH_ORIGINAL_COMMAND="zfs send -i tank/data@a tank/data@b"
  run "$AUTH_SCRIPT" --allow-send tank/data
  [ "$status" -eq 0 ]
  grep -qx "zfs send -i tank/data@a tank/data@b" "$MOCK_ZFS_LOG"
}

@test "allows send -I with --allow-send" {
  export SSH_ORIGINAL_COMMAND="zfs send -I tank/data@a tank/data@b"
  run "$AUTH_SCRIPT" --allow-send tank/data
  [ "$status" -eq 0 ]
  grep -qx "zfs send -I tank/data@a tank/data@b" "$MOCK_ZFS_LOG"
}

@test "allows a bookmark as incremental source with --allow-send" {
  export SSH_ORIGINAL_COMMAND="zfs send -i tank/data#a tank/data@b"
  run "$AUTH_SCRIPT" --allow-send tank/data
  [ "$status" -eq 0 ]
  grep -qx "zfs send -i tank/data#a tank/data@b" "$MOCK_ZFS_LOG"
}

@test "allows raw, compressed, large-block and embedded flags with --allow-send" {
  export SSH_ORIGINAL_COMMAND="zfs send -w -c -L -e -i tank/data@a tank/data@b"
  run "$AUTH_SCRIPT" --allow-send tank/data
  [ "$status" -eq 0 ]
  grep -qx "zfs send -w -c -L -e -i tank/data@a tank/data@b" "$MOCK_ZFS_LOG"
}

@test "allows send from a descendant of the allowed filesystem" {
  export SSH_ORIGINAL_COMMAND="zfs send -i tank/data/child@a tank/data/child@b"
  run "$AUTH_SCRIPT" --allow-send tank/data
  [ "$status" -eq 0 ]
  grep -qx "zfs send -i tank/data/child@a tank/data/child@b" "$MOCK_ZFS_LOG"
}

@test "denies send without --allow-send" {
  export SSH_ORIGINAL_COMMAND="zfs send tank/data@snap1"
  run "$AUTH_SCRIPT" tank/data
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed"* ]]
  log_not_contains "$MOCK_ZFS_LOG" "zfs"
}

@test "denies send with no arguments configured" {
  export SSH_ORIGINAL_COMMAND="zfs send tank/data@snap1"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed"* ]]
  log_not_contains "$MOCK_ZFS_LOG" "zfs"
}

@test "--allow-send without a filesystem refuses every command" {
  for cmd in "zfs send tank/data@snap1" "zfs receive tank/data" \
             "zfs list -t snapshot -s creation -o name -d 1 -H tank/data"; do
    export SSH_ORIGINAL_COMMAND="$cmd"
    run "$AUTH_SCRIPT" --allow-send
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires a filesystem"* ]]
  done
  log_not_contains "$MOCK_ZFS_LOG" "zfs"
}

@test "extra arguments in the key line refuse every command" {
  export SSH_ORIGINAL_COMMAND="zfs receive backup/data"
  run "$AUTH_SCRIPT" backup/data --allow-send
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage"* ]]
  log_not_contains "$MOCK_ZFS_LOG" "zfs"
}

@test "denies send from outside the allowed filesystem" {
  for snap in tank/other@snap1 tank/database@snap1; do
    export SSH_ORIGINAL_COMMAND="zfs send $snap"
    run "$AUTH_SCRIPT" --allow-send tank/data
    [ "$status" -eq 1 ]
    [[ "$output" == *"send from '$snap' not allowed"* ]]
  done
  log_not_contains "$MOCK_ZFS_LOG" "zfs"
}

@test "denies send of a filesystem instead of a snapshot" {
  export SSH_ORIGINAL_COMMAND="zfs send tank/data"
  run "$AUTH_SCRIPT" --allow-send tank/data
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed"* ]]
  log_not_contains "$MOCK_ZFS_LOG" "zfs"
}

@test "denies an incremental source from another dataset" {
  for src in tank/other@a tank/data/child@a tank/data; do
    export SSH_ORIGINAL_COMMAND="zfs send -i $src tank/data@b"
    run "$AUTH_SCRIPT" --allow-send tank/data
    [ "$status" -eq 1 ]
    [[ "$output" == *"not allowed"* ]]
  done
  log_not_contains "$MOCK_ZFS_LOG" "zfs"
}

@test "denies send flags outside the allowed set" {
  for flags in "-R" "-wc" "-p" "-v" "-i" "-w -i tank/data@a -c"; do
    export SSH_ORIGINAL_COMMAND="zfs send $flags tank/data@b"
    run "$AUTH_SCRIPT" --allow-send tank/data
    [ "$status" -eq 1 ]
    [[ "$output" == *"not allowed"* ]]
  done
  log_not_contains "$MOCK_ZFS_LOG" "zfs"
}

@test "denies pigz prefix with send" {
  export SSH_ORIGINAL_COMMAND="pigz -d | zfs send tank/data@snap1"
  run "$AUTH_SCRIPT" --allow-send tank/data
  [ "$status" -eq 1 ]
  [[ "$output" == *"not allowed"* ]]
  log_not_contains "$MOCK_ZFS_LOG" "zfs"
}

@test "--allow-send limits zfs list to the allowed filesystem" {
  export SSH_ORIGINAL_COMMAND="zfs list -t snapshot -s creation -o name -d 1 -H tank/other"
  run "$AUTH_SCRIPT" --allow-send tank/data
  [ "$status" -eq 1 ]
  [[ "$output" == *"list of 'tank/other' not allowed"* ]]
  export SSH_ORIGINAL_COMMAND="zfs list -t snapshot -s creation -o name -rH tank/database"
  run "$AUTH_SCRIPT" --allow-send tank/data
  [ "$status" -eq 1 ]
  log_not_contains "$MOCK_ZFS_LOG" "zfs"

  export SSH_ORIGINAL_COMMAND="zfs list -t snapshot -s creation -o name -d 1 -H tank/data/child"
  run "$AUTH_SCRIPT" --allow-send tank/data
  [ "$status" -eq 0 ]
  grep -qx "zfs list -t snapshot -s creation -o name -d 1 -H tank/data/child" "$MOCK_ZFS_LOG"
}

@test "zfs list stays unrestricted without --allow-send" {
  export SSH_ORIGINAL_COMMAND="zfs list -t snapshot -s creation -o name -d 1 -H tank/other"
  run "$AUTH_SCRIPT" backup/data
  [ "$status" -eq 0 ]
  grep -qx "zfs list -t snapshot -s creation -o name -d 1 -H tank/other" "$MOCK_ZFS_LOG"
}

@test "receive is still limited to the filesystem with --allow-send" {
  export SSH_ORIGINAL_COMMAND="zfs receive -F tank/data/child"
  run "$AUTH_SCRIPT" --allow-send tank/data
  [ "$status" -eq 0 ]
  grep -qx "zfs receive -F tank/data/child" "$MOCK_ZFS_LOG"
  export SSH_ORIGINAL_COMMAND="zfs receive -F tank/other"
  run "$AUTH_SCRIPT" --allow-send tank/data
  [ "$status" -eq 1 ]
  [[ "$output" == *"receive into 'tank/other' not allowed"* ]]
}
