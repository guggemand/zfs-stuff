#!/usr/bin/env bats

load test_helper

# --- Argument validation ---

@test "exits with error when no arguments given" {
  run "$CLEANSNAP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "exits with error when too few arguments given" {
  run "$CLEANSNAP" tank/data 7 4 3
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

# --- Filesystem validation ---

@test "exits with error for invalid filesystem" {
  export MOCK_ZFS_VALID_FS="tank/other"
  run "$CLEANSNAP" tank/data 7 4 3 2
  [ "$status" -eq 1 ]
}

# --- Basic retention ---

@test "keeps snapshots from the last 24 hours" {
  # FAKE_NOW is 2025-01-15 12:00:00
  RECENT=$(epoch "2025-01-15 08:00:00")   # 4 hours ago
  OLD=$(epoch "2025-01-14 00:00:00")      # 36 hours ago

  add_snap "tank/data@snap-old" "$OLD"
  add_snap "tank/data@snap-recent" "$RECENT"

  run "$CLEANSNAP" tank/data 1 0 0 0
  [ "$status" -eq 0 ]
  was_not_destroyed "snap-recent"
}

@test "always keeps the newest snapshot" {
  T1=$(epoch "2024-06-01 00:00:00")
  T2=$(epoch "2024-07-01 00:00:00")

  add_snap "tank/data@snap-1" "$T1"
  add_snap "tank/data@snap-2" "$T2"

  # Both are old, but newest must be kept. Only 1 of 2 deleted = 50%, allowed.
  run "$CLEANSNAP" tank/data 1 0 0 0
  [ "$status" -eq 0 ]
  was_not_destroyed "snap-2"
  was_destroyed "snap-1"
}

# --- 50% safety check ---

@test "refuses to delete more than 50% of snapshots" {
  for i in 1 2 3 4; do
    T=$(epoch "2024-0$i-01 00:00:00")
    add_snap "tank/data@snap-$i" "$T"
  done

  # 1 day retention -- would keep only newest (snap-4), delete 3 of 4 = 75%
  run "$CLEANSNAP" tank/data 1 0 0 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot remove more than 50%"* ]]
}

@test "JustDoIt overrides the 50% safety check" {
  for i in 1 2 3 4; do
    T=$(epoch "2024-0$i-01 00:00:00")
    add_snap "tank/data@snap-$i" "$T"
  done

  run "$CLEANSNAP" tank/data 1 0 0 0 JustDoIt
  [ "$status" -eq 0 ]
}

# --- Daily retention ---

@test "keeps correct number of daily snapshots" {
  # 5 snapshots over 5 days, keep 3 daily
  # With 5 total: keep 3, delete 2 → 40%, under 50% limit
  for i in $(seq 0 4); do
    DAY=$(printf '%02d' $((15 - i)))
    T=$(epoch "2025-01-$DAY 06:00:00")
    add_snap "tank/data@snap-jan$DAY" "$T"
  done

  run "$CLEANSNAP" tank/data 3 0 0 0
  [ "$status" -eq 0 ]

  # Days 15,14,13 should be kept (3 daily + 24h keeps 15)
  was_not_destroyed "snap-jan15"
  was_not_destroyed "snap-jan14"
  was_not_destroyed "snap-jan13"

  # Day 11 (4 days ago) should be deleted
  was_destroyed "snap-jan11"
}

# --- Weekly retention ---

@test "keeps weekly snapshots" {
  # 4 snapshots over 4 weeks, keep 2 weekly
  # Keep 2 + newest = ~3, delete 1 of 4 = 25%
  for i in $(seq 0 3); do
    DAYS_AGO=$(( i * 7 ))
    T=$(epoch_offset "2025-01-15 06:00:00" "-${DAYS_AGO}")
    add_snap "tank/data@snap-week$i" "$T"
  done

  run "$CLEANSNAP" tank/data 1 2 0 0
  [ "$status" -eq 0 ]

  # week0 (today) kept by 24h/daily, week1 and week2 kept by weekly
  was_not_destroyed "snap-week0"
}

# --- Monthly retention ---

@test "keeps monthly snapshots" {
  # Create 4 snapshots, one per month. Keep 3 monthly.
  # Keep 3, delete 1 of 4 = 25%
  T0=$(epoch "2025-01-02 06:00:00")
  T1=$(epoch "2024-12-02 06:00:00")
  T2=$(epoch "2024-11-02 06:00:00")
  T3=$(epoch "2024-10-02 06:00:00")

  add_snap "tank/data@snap-month0" "$T0"
  add_snap "tank/data@snap-month1" "$T1"
  add_snap "tank/data@snap-month2" "$T2"
  add_snap "tank/data@snap-month3" "$T3"

  run "$CLEANSNAP" tank/data 1 0 3 0
  [ "$status" -eq 0 ]

  was_not_destroyed "snap-month0"
  was_not_destroyed "snap-month1"
  was_not_destroyed "snap-month2"
  was_destroyed "snap-month3"
}

# --- Yearly retention ---

@test "keeps yearly snapshots" {
  # 3 snapshots over 3 years, keep 2 yearly
  # Keep 2, delete 1 of 3 = 33%
  T0=$(epoch "2025-01-02 06:00:00")
  T1=$(epoch "2024-01-02 06:00:00")
  T2=$(epoch "2023-01-02 06:00:00")

  add_snap "tank/data@snap-year0" "$T0"
  add_snap "tank/data@snap-year1" "$T1"
  add_snap "tank/data@snap-year2" "$T2"

  run "$CLEANSNAP" tank/data 1 0 0 2
  [ "$status" -eq 0 ]

  was_not_destroyed "snap-year0"
  was_not_destroyed "snap-year1"
  was_destroyed "snap-year2"
}

# --- Bookmark support ---

@test "creates bookmarks for snapshots in bookmark retention window" {
  # 4 snapshots over 4 days: keep 2 daily, 2 as bookmarks
  # Keep 2, remove 2 → exactly 50%, allowed
  for i in $(seq 0 3); do
    DAY=$(printf '%02d' $((15 - i)))
    T=$(epoch "2025-01-$DAY 06:00:00")
    add_snap "tank/data@snap-$DAY" "$T"
  done

  run "$CLEANSNAP" tank/data 2:2 0 0 0
  [ "$status" -eq 0 ]

  # Check that bookmark commands were logged for the bookmark-window snapshots
  grep -q "zfs bookmark" "$MOCK_ZFS_LOG"
}

@test "bookmark retention does not bookmark already-kept snapshots" {
  # 3 snapshots, 2 daily + 1 bookmark day
  # All 3 days covered (2 snap + 1 bm), nothing fully deleted
  for i in $(seq 0 2); do
    DAY=$(printf '%02d' $((15 - i)))
    T=$(epoch "2025-01-$DAY 06:00:00")
    add_snap "tank/data@snap-$DAY" "$T"
  done

  run "$CLEANSNAP" tank/data 2:1 0 0 0
  [ "$status" -eq 0 ]

  # snap-15 and snap-14 kept as snapshots (daily + 24h)
  was_not_destroyed "snap-15"
  was_not_destroyed "snap-14"
}

# --- Duplicate creation time ---

@test "warns and skips snapshots with duplicate creation times" {
  T=$(epoch "2025-01-14 06:00:00")
  add_snap "tank/data@snap-a" "$T"
  add_snap "tank/data@snap-b" "$T"
  add_snap "tank/data@snap-c" "$(epoch '2025-01-15 06:00:00')"

  run "$CLEANSNAP" tank/data 7 0 0 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"Warning: duplicate creation time"* ]]
}

# --- DST transitions (CET/CEST) ---
# Spring forward: 2025-03-30 02:00 CET → 03:00 CEST (23-hour day)
# Fall back:      2025-10-26 03:00 CEST → 02:00 CET  (25-hour day)

@test "daily retention works across spring forward (23-hour day)" {
  export FAKE_NOW="2025-03-31 12:00:00"

  # Snapshots around the spring-forward transition
  add_snap "tank/data@snap-mar31" "$(epoch '2025-03-31 06:00:00')"  # today
  add_snap "tank/data@snap-mar30" "$(epoch '2025-03-30 06:00:00')"  # DST day (23h)
  add_snap "tank/data@snap-mar29" "$(epoch '2025-03-29 06:00:00')"  # day before
  add_snap "tank/data@snap-mar28" "$(epoch '2025-03-28 06:00:00')"  # 3 days ago

  # Keep 3 daily -- should keep mar31, mar30, mar29 despite 23h day
  run "$CLEANSNAP" tank/data 3 0 0 0
  [ "$status" -eq 0 ]

  was_not_destroyed "snap-mar31"
  was_not_destroyed "snap-mar30"
  was_not_destroyed "snap-mar29"
  was_destroyed "snap-mar28"
}

@test "daily retention works across fall back (25-hour day)" {
  export FAKE_NOW="2025-10-27 12:00:00"

  # Snapshots around the fall-back transition
  add_snap "tank/data@snap-oct27" "$(epoch '2025-10-27 06:00:00')"  # today
  add_snap "tank/data@snap-oct26" "$(epoch '2025-10-26 06:00:00')"  # DST day (25h)
  add_snap "tank/data@snap-oct25" "$(epoch '2025-10-25 06:00:00')"  # day before
  add_snap "tank/data@snap-oct24" "$(epoch '2025-10-24 06:00:00')"  # 3 days ago

  # Keep 3 daily -- should keep oct27, oct26, oct25 despite 25h day
  run "$CLEANSNAP" tank/data 3 0 0 0
  [ "$status" -eq 0 ]

  was_not_destroyed "snap-oct27"
  was_not_destroyed "snap-oct26"
  was_not_destroyed "snap-oct25"
  was_destroyed "snap-oct24"
}

@test "24h keep window uses epoch seconds not wall-clock hours" {
  # During spring forward, 24 wall-clock hours = 23 real hours (82800s).
  # The 24h rule uses 86400 real seconds, so a snapshot from 23.5 wall-clock
  # hours ago (84600 real seconds) is still within the 86400s window.
  export FAKE_NOW="2025-03-30 12:00:00"

  # Snapshot from Mar 29 13:00 CET = 23 wall-clock hours before Mar 30 12:00 CEST
  # but only 82800 real seconds ago (< 86400) → should be kept
  add_snap "tank/data@snap-kept" "$(epoch '2025-03-29 13:00:00')"
  add_snap "tank/data@snap-newest" "$(epoch '2025-03-30 06:00:00')"

  run "$CLEANSNAP" tank/data 1 0 0 0
  [ "$status" -eq 0 ]

  was_not_destroyed "snap-kept"
  was_not_destroyed "snap-newest"
}

@test "24h keep window drops snapshot beyond 86400 real seconds during fall back" {
  # During fall back, 24 wall-clock hours = 25 real hours (90000s).
  # A snapshot from 24.5 wall-clock hours ago is 25.5 real hours (91800s)
  # which exceeds 86400s → deleted (unless saved by daily retention).
  export FAKE_NOW="2025-10-26 12:00:00"

  # Snapshot from Oct 25 11:30 CEST = 24.5 wall-clock hours before Oct 26 12:00 CET
  # but 91800 real seconds ago (> 86400) → outside 24h window
  # With only 1-day retention and 2 snapshots total, the newest is kept,
  # and this one falls in "today" daily bucket → kept by daily retention
  add_snap "tank/data@snap-borderline" "$(epoch '2025-10-25 11:30:00')"
  add_snap "tank/data@snap-newest" "$(epoch '2025-10-26 06:00:00')"

  run "$CLEANSNAP" tank/data 1 0 0 0
  [ "$status" -eq 0 ]

  # Even though it's outside the 24h epoch window, the daily retention
  # for "0 days ago 00:00" (midnight Oct 26) picks up snap-newest,
  # and snap-borderline is NOT picked up by any daily bucket → deleted
  was_not_destroyed "snap-newest"
  was_destroyed "snap-borderline"
}

# --- Combined retention ---

@test "weekly retention saves a snapshot that daily would delete" {
  # FAKE_NOW is 2025-01-15 (Wednesday). 3 daily + 2 weekly.
  # "1 week ago sunday" = 2025-01-08, "2 weeks ago sunday" = 2025-01-01
  add_snap "tank/data@snap-jan15" "$(epoch '2025-01-15 06:00:00')"  # today
  add_snap "tank/data@snap-jan14" "$(epoch '2025-01-14 06:00:00')"  # 1 day ago
  add_snap "tank/data@snap-jan13" "$(epoch '2025-01-13 06:00:00')"  # 2 days ago
  add_snap "tank/data@snap-jan09" "$(epoch '2025-01-09 06:00:00')"  # first snap >= Jan 8
  add_snap "tank/data@snap-jan02" "$(epoch '2025-01-02 06:00:00')"  # first snap >= Jan 1
  add_snap "tank/data@snap-dec25" "$(epoch '2024-12-25 06:00:00')"  # outside all windows

  # 3 daily keeps jan15,14,13.
  # weekly 1 ("1 week ago sunday" = Jan 8): first snap >= Jan 8 is jan09 → kept
  # weekly 2 ("2 weeks ago sunday" = Jan 1): first snap >= Jan 1 is jan02 → kept
  run "$CLEANSNAP" tank/data 3 2 0 0
  [ "$status" -eq 0 ]

  was_not_destroyed "snap-jan15"
  was_not_destroyed "snap-jan14"
  was_not_destroyed "snap-jan13"
  was_not_destroyed "snap-jan09"   # saved by weekly
  was_not_destroyed "snap-jan02"   # saved by weekly
  was_destroyed "snap-dec25"     # not covered by any policy
}

@test "combined daily weekly monthly yearly retention" {
  # FAKE_NOW is 2025-01-15 12:00:00
  add_snap "tank/data@snap-today"    "$(epoch '2025-01-15 06:00:00')"
  add_snap "tank/data@snap-3d"       "$(epoch '2025-01-12 06:00:00')"  # daily
  add_snap "tank/data@snap-1w"       "$(epoch '2025-01-06 06:00:00')"  # weekly
  add_snap "tank/data@snap-1m"       "$(epoch '2024-12-02 06:00:00')"  # monthly
  add_snap "tank/data@snap-1y"       "$(epoch '2024-01-02 06:00:00')"  # yearly
  add_snap "tank/data@snap-old"      "$(epoch '2022-06-01 06:00:00')"  # nothing

  run "$CLEANSNAP" tank/data 3 1 2 2
  [ "$status" -eq 0 ]

  was_not_destroyed "snap-today"
  was_not_destroyed "snap-3d"
  was_not_destroyed "snap-1w"
  was_not_destroyed "snap-1m"
  was_not_destroyed "snap-1y"
  was_destroyed "snap-old"
}

# --- All recent snapshots ---

@test "deletes nothing when all snapshots are within 24 hours" {
  add_snap "tank/data@snap-a" "$(epoch '2025-01-15 06:00:00')"
  add_snap "tank/data@snap-b" "$(epoch '2025-01-15 08:00:00')"
  add_snap "tank/data@snap-c" "$(epoch '2025-01-15 10:00:00')"

  run "$CLEANSNAP" tank/data 1 0 0 0
  [ "$status" -eq 0 ]

  was_not_destroyed "snap-a"
  was_not_destroyed "snap-b"
  was_not_destroyed "snap-c"
}

# --- Single snapshot ---

@test "keeps a single snapshot even if outside all retention windows" {
  add_snap "tank/data@snap-only" "$(epoch '2020-01-01 06:00:00')"

  run "$CLEANSNAP" tank/data 1 0 0 0
  [ "$status" -eq 0 ]

  was_not_destroyed "snap-only"
}

# --- Destroy flags ---

@test "snapshots are destroyed with -d (deferred) flag" {
  add_snap "tank/data@snap-new" "$(epoch '2025-01-15 06:00:00')"
  add_snap "tank/data@snap-old" "$(epoch '2025-01-14 00:00:00')"

  run "$CLEANSNAP" tank/data 1 0 0 0
  [ "$status" -eq 0 ]

  was_destroyed_deferred "snap-old"
}

@test "bookmarks are destroyed without -d flag" {
  # Use bookmark retention so the listing includes bookmarks
  add_snap "tank/data@snap-new"          "$(epoch '2025-01-15 06:00:00')"
  add_snap "tank/data@snap-recent"       "$(epoch '2025-01-14 06:00:00')"
  add_bookmark "tank/data#snap-ancient"  "$(epoch '2024-01-01 06:00:00')"

  # 2 daily + 1 bookmark day. The old bookmark is outside all windows.
  run "$CLEANSNAP" tank/data 2:1 0 0 0
  [ "$status" -eq 0 ]

  was_destroyed "snap-ancient"
  was_destroyed_immediate "snap-ancient"
}

# --- Existing bookmark cleanup ---

@test "keeps bookmarks within bookmark retention window" {
  add_snap "tank/data@snap-new"          "$(epoch '2025-01-15 06:00:00')"
  add_snap "tank/data@snap-yesterday"    "$(epoch '2025-01-14 06:00:00')"
  add_snap "tank/data@snap-2dago"        "$(epoch '2025-01-13 06:00:00')"
  add_bookmark "tank/data#snap-3dago"    "$(epoch '2025-01-12 06:00:00')"
  add_bookmark "tank/data#snap-veryold"  "$(epoch '2024-06-01 06:00:00')"

  # 3 daily + 2 bookmark days. The bookmark at day 4 falls in bookmark window.
  # Keep 3 snaps, 2 removed (50% check: 2 > 3? no → ok)
  run "$CLEANSNAP" tank/data 3:2 0 0 0
  [ "$status" -eq 0 ]

  # The 3-day-ago bookmark is within the bookmark window → kept
  was_not_destroyed "snap-3dago"
  # The very old bookmark is outside all windows → deleted
  was_destroyed "snap-veryold"
}

@test "deletes bookmarks outside all retention windows" {
  add_snap "tank/data@snap-new"         "$(epoch '2025-01-15 06:00:00')"
  add_snap "tank/data@snap-yesterday"   "$(epoch '2025-01-14 06:00:00')"
  add_bookmark "tank/data#snap-veryold" "$(epoch '2024-01-01 06:00:00')"

  # 2 daily + 1 bookmark day -- the old bookmark is far outside
  run "$CLEANSNAP" tank/data 2:1 0 0 0
  [ "$status" -eq 0 ]

  was_destroyed "snap-veryold"
}

# --- No snapshots scenario ---

@test "exits with error when no snapshots exist" {
  run "$CLEANSNAP" tank/data 7 4 3 2
  [ "$status" -eq 1 ]
}
