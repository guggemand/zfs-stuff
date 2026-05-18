#!/usr/bin/env bats

#
# Tests for sendwithpigz.sh
#

load test_helper

setup() {
  common_setup
  MOCK_BIN="$TEST_TMPDIR/bin"
  mkdir -p "$MOCK_BIN"

  # Log files for each mock
  export SSH_LOG="$TEST_TMPDIR/ssh.log"
  export PIGZ_LOG="$TEST_TMPDIR/pigz.log"
  export MBUFFER_LOG="$TEST_TMPDIR/mbuffer.log"

  # Mock ssh: log arguments, exit 0
  cat > "$MOCK_BIN/ssh" <<'MOCK'
#!/bin/sh
echo "ssh $*" >> "$SSH_LOG"
exit 0
MOCK
  chmod +x "$MOCK_BIN/ssh"

  # Mock pigz: pass stdin through, log arguments
  cat > "$MOCK_BIN/pigz" <<'MOCK'
#!/bin/sh
echo "pigz $*" >> "$PIGZ_LOG"
cat
MOCK
  chmod +x "$MOCK_BIN/pigz"

  # Mock mbuffer: pass stdin through, log arguments.
  # Created executable by default; tests that need the no-mbuffer branch
  # use chmod -x to make it non-executable.
  cat > "$MOCK_BIN/mbuffer" <<'MOCK'
#!/bin/sh
echo "mbuffer $*" >> "$MBUFFER_LOG"
cat
MOCK
  chmod +x "$MOCK_BIN/mbuffer"
}

teardown() {
  common_teardown
}

# --- Argument validation ---

@test "exits with error when no arguments given" {
  run "$SENDWITHPIGZ"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "exits with error when only host given (missing list/receive)" {
  run "$SENDWITHPIGZ" user@remotehost
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "exits with error for unsupported subcommand" {
  run env PATH="$MOCK_BIN:$PATH" "$SENDWITHPIGZ" user@remotehost destroy
  [ "$status" -eq 1 ]
  [[ "$output" == *'only "list" and "receive" is supported'* ]]
}

# --- list subcommand ---

@test "list calls ssh with correct zfs list arguments" {
  run env PATH="$MOCK_BIN:$PATH" "$SENDWITHPIGZ" user@remotehost list -t snapshot -o name tank/data
  [ "$status" -eq 0 ]
  [ -f "$SSH_LOG" ]
  grep -q "ssh user@remotehost /sbin/zfs list -t snapshot -o name tank/data" "$SSH_LOG"
}

# --- receive subcommand without mbuffer ---

@test "receive without mbuffer calls pigz and ssh with correct arguments" {
  # Make mbuffer non-executable: command -v still finds it (bash 5.x returns
  # the path for non-executable files) so the set -e assignment succeeds,
  # but [ -x "$MBUFFER" ] fails, taking the no-mbuffer code path.
  # The script's #!/bin/sh resolves to bash 3.2 on macOS which would abort
  # on command -v failure, so we run explicitly with bash (Homebrew 5.x).
  chmod -x "$MOCK_BIN/mbuffer"

  run env PATH="$MOCK_BIN:$PATH" bash "$SENDWITHPIGZ" user@remotehost receive -F tank/data </dev/null
  [ "$status" -eq 0 ]

  # mbuffer should NOT have been called
  [ ! -s "$MBUFFER_LOG" ]

  # pigz was called (sender side, no arguments for compression)
  [ -f "$PIGZ_LOG" ]

  # ssh was called with the correct remote command
  [ -f "$SSH_LOG" ]
  grep -q "ssh user@remotehost pigz -d | /sbin/zfs receive -F tank/data" "$SSH_LOG"
}

# --- receive subcommand with mbuffer ---

@test "receive with mbuffer calls mbuffer, pigz and ssh" {
  run env PATH="$MOCK_BIN:$PATH" "$SENDWITHPIGZ" user@remotehost receive -F tank/data </dev/null
  [ "$status" -eq 0 ]

  # mbuffer was called with the right buffer arguments
  [ -f "$MBUFFER_LOG" ]
  grep -q "mbuffer -m 1G -q -s 128k" "$MBUFFER_LOG"

  # pigz was called
  [ -f "$PIGZ_LOG" ]

  # ssh was called with the correct remote command
  [ -f "$SSH_LOG" ]
  grep -q "ssh user@remotehost pigz -d | /sbin/zfs receive -F tank/data" "$SSH_LOG"
}
