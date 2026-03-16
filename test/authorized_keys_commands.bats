#!/usr/bin/env bats

setup() {
  AUTH_SCRIPT="$BATS_TEST_DIRNAME/../authorized_keys_commands.sh"
  MOCK_DIR="$BATS_TEST_DIRNAME/mocks"
  TEST_TMPDIR=$(mktemp -d)

  export PATH="$MOCK_DIR:$PATH"
  export MOCK_ZFS_ACCEPT_ALL=1
  export MOCK_ZFS_LOG="$TEST_TMPDIR/zfs.log"
  touch "$MOCK_ZFS_LOG"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# --- Allowed: list ---

@test "allows zfs list with correct arguments" {
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
}

@test "allows pigz prefix with zfs receive -F" {
  export SSH_ORIGINAL_COMMAND="pigz -d | zfs receive -F tank/backup"
  run "$AUTH_SCRIPT" </dev/null
  [ "$status" -eq 0 ]
}

@test "allows pigz prefix with zfs list" {
  export SSH_ORIGINAL_COMMAND="pigz -d | zfs list -t snapshot -s creation -o name -rH tank/data"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 0 ]
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

@test "semicolon injection is harmless -- extra args silently dropped" {
  # "set --" splits by whitespace, so "; rm -rf /" becomes extra positional
  # parameters that are never used. The semicolon becomes part of the
  # filesystem name ("tank/data;") which zfs would reject, but the
  # injected command is never executed.
  export SSH_ORIGINAL_COMMAND="zfs receive tank/data; rm -rf /"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 0 ]
  # Verify "rm" was never executed -- only zfs was called
  grep -q "zfs receive" "$MOCK_ZFS_LOG"
  if grep -q "rm" "$MOCK_ZFS_LOG"; then
    echo "Injected 'rm' command was executed" >&2
    return 1
  fi
}

@test "pipe injection after list is harmless -- extra args silently dropped" {
  # The pipe character "|" is not interpreted by the shell since the script
  # uses set -- (word splitting only). Extra positional parameters beyond
  # ${10} are simply ignored.
  export SSH_ORIGINAL_COMMAND="zfs list -t snapshot -s creation -o name -rH tank/data | cat /etc/passwd"
  run "$AUTH_SCRIPT"
  [ "$status" -eq 0 ]
  # Verify only the zfs list command was executed, not "cat /etc/passwd"
  grep -q "zfs list" "$MOCK_ZFS_LOG"
  if grep -q "cat" "$MOCK_ZFS_LOG"; then
    echo "Injected 'cat' command was executed" >&2
    return 1
  fi
}

# --- Glob safety (set -f) ---

@test "glob characters in filesystem name are not expanded" {
  # Create files matching "tank/*" so the glob would expand without set -f
  mkdir -p "$TEST_TMPDIR/tank"
  touch "$TEST_TMPDIR/tank/vol1" "$TEST_TMPDIR/tank/vol2"

  export SSH_ORIGINAL_COMMAND="zfs receive tank/*"
  # Run from the temp dir so the glob could match real files
  run bash -c "cd $TEST_TMPDIR && $AUTH_SCRIPT"
  [ "$status" -eq 0 ]
  # Verify the literal * was passed to zfs, not expanded to "tank/vol1 tank/vol2"
  grep -q 'zfs receive tank/\*' "$MOCK_ZFS_LOG"
}
