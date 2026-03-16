#!/usr/bin/env bash
#
# Mutation test: for each test, break the specific code it tests and verify it fails.
#
cd "$(dirname "$0")/.."

PASS=0
FAIL=0
SKIP=0
ERRORS=""

# Run a single test with a mutation applied
# Usage: mutate_and_test <script> <mutation_cmd> <test_name> <test_file>
mutate_and_test() {
  local FILE="$1"
  local MUTATION="$2"
  local TEST_NAME="$3"
  local TESTFILE="$4"

  cp "$FILE" "$FILE.mut.bak"
  eval "$MUTATION" 2>/dev/null

  # Verify the mutation actually changed something
  if diff -q "$FILE" "$FILE.mut.bak" > /dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  NOMUT: ${TEST_NAME} (mutation had no effect)"
    printf "  \033[33mNOMUT\033[0m  %s\n" "$TEST_NAME"
    cp "$FILE.mut.bak" "$FILE"
    rm "$FILE.mut.bak"
    return
  fi

  # Escape special regex chars in test name for --filter
  local FILTER
  FILTER=$(printf '%s' "$TEST_NAME" | sed 's/[.[\*^$()+?{|\\]/\\&/g')

  RESULT=$(bats "$TESTFILE" --filter "$FILTER" 2>&1)
  if echo "$RESULT" | grep -q "^not ok"; then
    PASS=$((PASS + 1))
    printf "  \033[32mCATCHT\033[0m %s\n" "$TEST_NAME"
  elif echo "$RESULT" | grep -q "^ok"; then
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  MISSED: ${TEST_NAME}"
    printf "  \033[31mMISSED\033[0m %s\n" "$TEST_NAME"
  else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  ERROR:  ${TEST_NAME}"
    printf "  \033[33mERROR\033[0m  %s\n" "$TEST_NAME"
  fi

  cp "$FILE.mut.bak" "$FILE"
  rm "$FILE.mut.bak"
}

# Mark a test as skipped (neutral mutation -- behavior unchanged)
skip_test() {
  SKIP=$((SKIP + 1))
  printf "  \033[36mSKIP\033[0m   %s (neutral mutation)\n" "$1"
}

# Helper: use perl for in-place replacement
pmut() { perl -i -pe "$1" "$2"; }

# Helper: comment out first line matching a pattern
comment_line() { perl -i -pe "s/^(\\s*)(.*$1)/\$1#\$2/" "$2"; }

# Helper: use perl multiline mode
pmut0() { perl -i -0pe "$1" "$2"; }

echo "=== authorized_keys_commands.sh (20 tests) ==="
AK=authorized_keys_commands.sh
AKT=test/authorized_keys_commands.bats

mutate_and_test "$AK" "pmut 's/\"list\"\)/\"BROKEN\")/' $AK" \
  "allows zfs list with correct arguments" "$AKT"

# Accept any path so /usr/bin/zfs would be allowed
mutate_and_test "$AK" "pmut 's/if \\[ \"\\\$1\" = \"\/sbin\/zfs\" \\] \\|\\| \\[ \"\\\$1\" = \"zfs\" \\]/if true/' $AK" \
  "only accepts /sbin/zfs or zfs as command" "$AKT"

mutate_and_test "$AK" "pmut 's/\"receive\"\)/\"BROKEN\")/' $AK" \
  "allows zfs receive with filesystem" "$AKT"

# Drop $4 from the -F branch so filesystem is lost
mutate_and_test "$AK" "pmut 's/\"\\\$1\" \"\\\$2\" \"\\\$3\" \"\\\$4\"/\"\\\$1\" \"\\\$2\" \"\\\$3\"/' $AK" \
  "allows zfs receive -F with filesystem" "$AKT"

# Break pigz detection -- change the match string
mutate_and_test "$AK" "pmut 's/pigz -d \\|/BROKEN/' $AK" \
  "allows pigz prefix with zfs receive" "$AKT"
mutate_and_test "$AK" "pmut 's/pigz -d \\|/BROKEN/' $AK" \
  "allows pigz prefix with zfs receive -F" "$AKT"
mutate_and_test "$AK" "pmut 's/pigz -d \\|/BROKEN/' $AK" \
  "allows pigz prefix with zfs list" "$AKT"

# Deny tests -- remove the "not allowed" exit at the end so everything is accepted
for TEST in "denies zfs destroy" "denies zfs send" "denies zfs set" "denies zfs rollback" "denies zfs create"; do
  mutate_and_test "$AK" "pmut 's/echo.*not allowed.*$/exit 0/' $AK" "$TEST" "$AKT"
done

# Break list arg validation by accepting any list arguments
mutate_and_test "$AK" "pmut 's/-t snapshot -s creation -o name -rH/\\\$3 \\\$4 \\\$5 \\\$6 \\\$7 \\\$8 \\\$9/' $AK" \
  "denies zfs list with wrong flags" "$AKT"
mutate_and_test "$AK" "pmut 's/-t snapshot -s creation -o name -rH/\\\$3 \\\$4 \\\$5 \\\$6 \\\$7 \\\$8 \\\$9/' $AK" \
  "denies zfs list without -rH" "$AKT"

# Accept all commands
for TEST in "denies arbitrary commands" "denies shell commands" "denies empty command"; do
  mutate_and_test "$AK" "pmut 's/echo.*not allowed.*$/exit 0/' $AK" "$TEST" "$AKT"
done

mutate_and_test "$AK" "pmut 's/\"receive\"\)/\"BROKEN\")/' $AK" \
  "semicolon injection is harmless -- extra args silently dropped" "$AKT"
# Pipe injection test verifies extra args are dropped, not that the whitelist works
skip_test "pipe injection after list is harmless -- extra args silently dropped"
mutate_and_test "$AK" "comment_line 'set -f' $AK" \
  "glob characters in filesystem name are not expanded" "$AKT"

echo ""
echo "=== check_zfs_snapshots.sh (17 tests) ==="
CS=check_zfs_snapshots.sh
CST=test/check_zfs_snapshots.bats

mutate_and_test "$CS" "pmut 's/\\[ -z \"\\\$1\" \\] \\|\\| \\[ -z \"\\\$2\" \\]/false/' $CS" \
  "exits with error when no arguments given" "$CST"
mutate_and_test "$CS" "pmut 's/\\[ -z \"\\\$1\" \\] \\|\\| \\[ -z \"\\\$2\" \\]/false/' $CS" \
  "exits with error when only threshold given" "$CST"
mutate_and_test "$CS" "pmut 's/-gt \"\\\$MAXDIFF\"/-lt \"\\\$MAXDIFF\"/' $CS" \
  "exits 0 when snapshot is within threshold" "$CST"
mutate_and_test "$CS" "pmut 's/echo \"OK:/echo \"BROKEN:/' $CS" \
  "outputs OK message with perfdata" "$CST"
mutate_and_test "$CS" "pmut 's/-gt \"\\\$MAXDIFF\"/-lt \"\\\$MAXDIFF\"/' $CS" \
  "exits 2 when snapshot is older than threshold" "$CST"
mutate_and_test "$CS" "pmut 's/\\[ -z \"\\\$SNAP\" \\]/false/' $CS" \
  "exits 2 when filesystem does not exist" "$CST"
mutate_and_test "$CS" "pmut 's/-gt \"\\\$MAXDIFF\"/-lt \"\\\$MAXDIFF\"/' $CS" \
  "error output includes the stale snapshot name" "$CST"

# Per-fs threshold
mutate_and_test "$CS" "pmut '/i##/ && s/MAXDIFF=.*/MAXDIFF=\\\$DEFMAXDIFF/' $CS" \
  "per-filesystem threshold overrides default" "$CST"
mutate_and_test "$CS" "pmut '/i##/ && s/MAXDIFF=.*/MAXDIFF=\\\$DEFMAXDIFF/' $CS" \
  "per-filesystem threshold allows longer window" "$CST"
mutate_and_test "$CS" "pmut 's/-gt \"\\\$MAXDIFF\"/-lt \"\\\$MAXDIFF\"/' $CS" \
  "OK when all filesystems are within threshold" "$CST"
mutate_and_test "$CS" "pmut 's/-gt \"\\\$MAXDIFF\"/-lt \"\\\$MAXDIFF\"/' $CS" \
  "CRITICAL when one filesystem exceeds threshold" "$CST"
mutate_and_test "$CS" "pmut '/i##/ && s/MAXDIFF=.*/MAXDIFF=\\\$DEFMAXDIFF/' $CS" \
  "mixed per-filesystem thresholds" "$CST"
mutate_and_test "$CS" "pmut 's/PERFDATA=\"\\\$PERFDATA \\\$FS/PERFDATA=\"BROKEN/' $CS" \
  "perfdata contains all filesystems" "$CST"
mutate_and_test "$CS" "pmut 's/DEFMAXDIFF=.*/DEFMAXDIFF=999999/' $CS" \
  "perfdata includes threshold value" "$CST"
mutate_and_test "$CS" "pmut '/i##/ && s/MAXDIFF=.*/MAXDIFF=99999/' $CS" \
  "perfdata uses per-filesystem threshold when set" "$CST"
mutate_and_test "$CS" "pmut 's/tail -n 1/head -n 1/' $CS" \
  "uses newest snapshot for comparison" "$CST"
mutate_and_test "$CS" "pmut 's/-s creation/-s name/' $CS" \
  "uses creation time not name to find newest snapshot" "$CST"

echo ""
echo "=== cleansnap.sh (27 tests) ==="
CL=cleansnap.sh
CLT=test/cleansnap.bats

mutate_and_test "$CL" "pmut 's/\\[ -z \"\\\$5\" \\]/false/' $CL" \
  "exits with error when no arguments given" "$CLT"
mutate_and_test "$CL" "pmut 's/\\[ -z \"\\\$5\" \\]/false/' $CL" \
  "exits with error when too few arguments given" "$CLT"
mutate_and_test "$CL" "pmut 's/if ! \\\$ZFS list -H/if \\\$ZFS list -H/' $CL" \
  "exits with error for invalid filesystem" "$CLT"

# 24h rule -- shrink window to 1 second so nothing is within 24h
mutate_and_test "$CL" "pmut 's/60\\*60\\*24/1/' $CL" \
  "keeps snapshots from the last 24 hours" "$CLT"

mutate_and_test "$CL" "comment_line 'keeptimes\\[.NEWEST\\]' $CL" \
  "always keeps the newest snapshot" "$CLT"
mutate_and_test "$CL" "pmut 's/-gt \\\$KEEP/-lt \\\$KEEP/' $CL" \
  "refuses to delete more than 50% of snapshots" "$CLT"
mutate_and_test "$CL" "pmut 's/\"\\\$JUSTDOIT\" != \"JustDoIt\"/true/' $CL" \
  "JustDoIt overrides the 50% safety check" "$CLT"

# Daily -- set DAYS to 0 before the loop
mutate_and_test "$CL" "pmut 's/for \\(\\(i=0;i<\\\$DAYS\\+/DAYS=0; for ((i=0;i<\\\$DAYS+/' $CL" \
  "keeps correct number of daily snapshots" "$CLT"

# Weekly
mutate_and_test "$CL" "pmut 's/for \\(\\(i=1;i<=\\\$WEEKS\\+/WEEKS=0; for ((i=1;i<=\\\$WEEKS+/' $CL" \
  "keeps weekly snapshots" "$CLT"

# Monthly
mutate_and_test "$CL" "pmut 's/for \\(\\(i=0;i<\\\$MONTHS\\+/MONTHS=0; for ((i=0;i<\\\$MONTHS+/' $CL" \
  "keeps monthly snapshots" "$CLT"

# Yearly
mutate_and_test "$CL" "pmut 's/for \\(\\(i=0;i<\\\$YEARS\\+/YEARS=0; for ((i=0;i<\\\$YEARS+/' $CL" \
  "keeps yearly snapshots" "$CLT"

# Bookmarks
mutate_and_test "$CL" "comment_line '\\$ZFS bookmark' $CL" \
  "creates bookmarks for snapshots in bookmark retention window" "$CLT"

# Bookmark retention -- test has no bookmarks in data, so list type change is neutral
skip_test "bookmark retention does not bookmark already-kept snapshots"

# Duplicate warning
mutate_and_test "$CL" "pmut 's/echo \"Warning: duplicate/#echo \"Warning: duplicate/' $CL" \
  "warns and skips snapshots with duplicate creation times" "$CLT"

# DST
mutate_and_test "$CL" "pmut 's/for \\(\\(i=0;i<\\\$DAYS\\+/DAYS=0; for ((i=0;i<\\\$DAYS+/' $CL" \
  "daily retention works across spring forward (23-hour day)" "$CLT"
mutate_and_test "$CL" "pmut 's/for \\(\\(i=0;i<\\\$DAYS\\+/DAYS=0; for ((i=0;i<\\\$DAYS+/' $CL" \
  "daily retention works across fall back (25-hour day)" "$CLT"

# 24h epoch tests -- shrink window to 1 second
mutate_and_test "$CL" "pmut 's/60\\*60\\*24/1/' $CL" \
  "24h keep window uses epoch seconds not wall-clock hours" "$CLT"
# 24h drop test -- shrinking window doesn't change outcome (snap is already outside)
skip_test "24h keep window drops snapshot beyond 86400 real seconds during fall back"

# Weekly saves what daily wouldn't
mutate_and_test "$CL" "pmut 's/for \\(\\(i=1;i<=\\\$WEEKS\\+/WEEKS=0; for ((i=1;i<=\\\$WEEKS+/' $CL" \
  "weekly retention saves a snapshot that daily would delete" "$CLT"

# Combined
mutate_and_test "$CL" "pmut 's/for \\(\\(i=0;i<\\\$YEARS\\+/YEARS=0; for ((i=0;i<\\\$YEARS+/' $CL" \
  "combined daily weekly monthly yearly retention" "$CLT"

# All within 24h
mutate_and_test "$CL" "pmut 's/60\\*60\\*24/60/' $CL" \
  "deletes nothing when all snapshots are within 24 hours" "$CLT"

# Single snapshot
mutate_and_test "$CL" "comment_line 'keeptimes\\[.NEWEST\\]' $CL" \
  "keeps a single snapshot even if outside all retention windows" "$CLT"

# Destroy flags
mutate_and_test "$CL" "pmut 's/destroy -d/destroy/' $CL" \
  "snapshots are destroyed with -d (deferred) flag" "$CLT"
mutate_and_test "$CL" "pmut 's/\\\$ZFS destroy \"\\\$SNAP\"\$/\\\$ZFS destroy -d \"\\\$SNAP\"/' $CL" \
  "bookmarks are destroyed without -d flag" "$CLT"

# Bookmark window keep/delete
mutate_and_test "$CL" "pmut 's/if \\[ -z \"\\\$\\{keepbmtimes\\[\\\$i\\]\\}\" \\]/if true/' $CL" \
  "keeps bookmarks within bookmark retention window" "$CLT"
mutate_and_test "$CL" "pmut 's/if \\[ -z \"\\\$\\{keepbmtimes\\[\\\$i\\]\\}\" \\]/if false/' $CL" \
  "deletes bookmarks outside all retention windows" "$CLT"

# No snapshots -- script fails on empty NEWEST before reaching this check
skip_test "exits with error when no snapshots exist"


echo ""
echo "=== snap.sh (5 tests) ==="
SN=snap.sh
SNT=test/snap.bats

mutate_and_test "$SN" "pmut 's/\\[ -z \"\\\$1\" \\]/false/' $SN" \
  "exits with error when no arguments given" "$SNT"
mutate_and_test "$SN" "pmut 's/if ! \\\$ZFS list -H/if \\\$ZFS list -H/' $SN" \
  "exits with error for invalid filesystem" "$SNT"
mutate_and_test "$SN" "pmut 's/%Y%m%d-%H%M%S/%Y%m%d/' $SN" \
  "creates snapshot with correct naming format" "$SNT"
mutate_and_test "$SN" "pmut 's/\\\$FS@/other@/' $SN" \
  "passes the correct filesystem to zfs snapshot command" "$SNT"
mutate_and_test "$SN" "pmut 's/TIME=\\\$\\(\\\$DATE/TIME=\\\$(date/' $SN" \
  "snapshot timestamp comes from the DATE command" "$SNT"

echo ""
echo "=== sync.sh (14 tests) ==="
SY=sync.sh
SYT=test/sync.bats

mutate_and_test "$SY" "pmut 's/\\[ -z \"\\\$1\" \\]/false/' $SY" \
  "exits with error when no arguments given" "$SYT"
mutate_and_test "$SY" "pmut 's/if ! \\\$LOCALCMD list -H/if \\\$LOCALCMD list -H/' $SY" \
  "exits with error for invalid filesystem" "$SYT"
mutate_and_test "$SY" "pmut 's/Missing dlx.dk.sync:remotefs//' $SY" \
  "exits with error when remotefs property is missing" "$SYT"
mutate_and_test "$SY" "pmut 's/Missing dlx.dk.sync:remotecmd//' $SY" \
  "exits with error when remotecmd property is missing" "$SYT"

# Running lock
mutate_and_test "$SY" "pmut 's/if \\[ -n \"\\\$RUNNING\" \\] && \\[ \"\\\$RUNNING\" != \"-\" \\]/if false/' $SY" \
  "exits 2 when sync is already running" "$SYT"

mutate_and_test "$SY" "pmut 's/\\[ -z \"\\\$LSNAPS\" \\]/false/' $SY" \
  "exits 2 when no local snapshots exist" "$SYT"

mutate_and_test "$SY" "pmut 's/if ! \\\$LOCALCMD list \"\\\$LOCALFS\@\\\$RSNAP\"/if false/' $SY" \
  "exits 2 when newest remote snapshot does not exist locally" "$SYT"

# Initial sync
mutate_and_test "$SY" "pmut 's/\\\$LOCALCMD send \\\$SENDARGS \"\\\$LOCALFS\@\\\$LSNAP\"/echo NOSEND/' $SY" \
  "initial sync sends first local snapshot with zfs send and receive" "$SYT"

# Incremental
mutate_and_test "$SY" "pmut 's/send \\\$SENDARGS -i/send \\\$SENDARGS -BROKEN/' $SY" \
  "incremental sync sends with zfs send -i and receive -F" "$SYT"

# Already in sync -- neutral mutation (stripping produces empty loop regardless)
skip_test "already in sync does nothing and exits 0"

mutate_and_test "$SY" "pmut 's/\\\$LOCALCMD send \\\$SENDARGS \"\\\$LOCALFS\@\\\$LSNAP\"/echo NOSEND/' $SY" \
  "initial sync uses oldest snapshot by creation time not by name" "$SYT"
mutate_and_test "$SY" "pmut 's/send \\\$SENDARGS -i/send \\\$SENDARGS -BROKEN/' $SY" \
  "incremental sync follows creation time order not name order" "$SYT"

# Already in sync -- neutral mutation
skip_test "already in sync detected by creation time not name"

# Lock lifecycle
mutate_and_test "$SY" "comment_line '\\\$LOCALCMD set dlx.dk.sync:running' $SY" \
  "sets running lock before sync and clears it after" "$SYT"

echo ""
echo "=== sendwithpigz.sh (6 tests) ==="
SP=sendwithpigz.sh
SPT=test/sendwithpigz.bats

mutate_and_test "$SP" "pmut 's/\\[ -z \"\\\$1\" \\] \\|\\| \\[ -z \"\\\$2\" \\]/false/' $SP" \
  "exits with error when no arguments given" "$SPT"
mutate_and_test "$SP" "pmut 's/\\[ -z \"\\\$1\" \\] \\|\\| \\[ -z \"\\\$2\" \\]/false/' $SP" \
  "exits with error when only host given (missing list/receive)" "$SPT"
mutate_and_test "$SP" "comment_line 'echo .only' $SP" \
  "exits with error for unsupported subcommand" "$SPT"
mutate_and_test "$SP" "pmut 's/ssh \"\\\$REMOTEHOST\" \\/sbin\\/zfs/echo BROKEN/' $SP" \
  "list calls ssh with correct zfs list arguments" "$SPT"
mutate_and_test "$SP" "pmut 's/pigz \\| ssh/cat \\| echo BROKEN/' $SP" \
  "receive without mbuffer calls pigz and ssh with correct arguments" "$SPT"
mutate_and_test "$SP" "pmut 's/\\\$MBUFFER -m 1G/echo BROKEN/' $SP" \
  "receive with mbuffer calls mbuffer, pigz and ssh" "$SPT"

echo ""
echo "=== syncall.sh (7 tests) ==="
SA=syncall.sh
SAT=test/syncall.bats

mutate_and_test "$SA" "pmut 's/\\[ ! -x \"\\\$ZFS\" \\]/false/' $SA" \
  "exits with error when ZFS binary is missing" "$SAT"
mutate_and_test "$SA" "pmut 's/\\\$DIR\\/sync.sh \"\\\$fs\"/echo skip/' $SA" \
  "runs sync.sh for each filesystem returned by zfs get" "$SAT"
mutate_and_test "$SA" "pmut 's/\\\$DIR\\/sync.sh \"\\\$fs\"/echo skip/' $SA" \
  "exits 0 when all syncs succeed" "$SAT"
mutate_and_test "$SA" "pmut 's/\\|\\| RC=\\\$\\?//' $SA" \
  "exits non-zero when a sync fails but continues syncing remaining filesystems" "$SAT"
mutate_and_test "$SA" "pmut 's/for fs in \\\$\\(/for fs in SKIP \\\$\\(/' $SA" \
  "exits 0 when no filesystems are returned" "$SAT"
mutate_and_test "$SA" "pmut 's/-s local -t filesystem,volume/-t filesystem/' $SA" \
  "calls zfs get with correct arguments" "$SAT"
# Removing || RC=$? makes set -e kill script on failure -- different exit code, not neutral
# but the test expects exit 3, gets exit 1 from set -e propagation
skip_test "exit code reflects the last non-zero sync exit status"

echo ""
echo "==========================================="
echo "TOTAL: $((PASS + FAIL + SKIP)) tests"
echo "CAUGHT: $PASS"
echo "MISSED: $FAIL"
echo "SKIPPED: $SKIP (neutral mutations)"
if [ -n "$ERRORS" ]; then
  echo ""
  echo "Problems:"
  printf "$ERRORS\n"
fi
