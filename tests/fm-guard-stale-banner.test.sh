#!/usr/bin/env bash
# Regression tests for fm-guard's stale-watcher banner deduplication.
#
# The first stale command in one FM_HOME must print the full actionable watcher
# banner.
# Repeated commands at the same outage escalation level should print only a
# concise reminder, while unrelated alarms such as queued wakes stay independent.
# A LENGTHENING outage must get louder rather than quieter: crossing a rung of
# the escalation ladder re-claims the full banner even though the episode never
# changed, and every line states how long supervision has been down.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-guard-stale-banner)

make_guard_case() {
  local name=$1 dir home root
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  root="$dir/root"
  mkdir -p "$home/state" "$home/config" "$root"
  fm_write_meta "$home/state/task.meta" "window=firstmate:fm-task" "kind=ship"
  printf '%s\n' "$dir"
}

case_home() {
  printf '%s/home\n' "$1"
}

case_root() {
  printf '%s/root\n' "$1"
}

# The guard also alarms on shared-temp-filesystem pressure, measured against the
# real host temp root. These cases are about the watcher banner and assert on the
# guard's whole output, so that independent alarm is pinned quiet here; without
# it the suite would fail on any host whose temp root happens to be 80% full,
# which is precisely the condition the temp alarm exists to report.
run_guard_case() {
  local dir=$1
  FM_TMP_USAGE_WARN=100 FM_TMP_USAGE_HIGH=100 FM_TMP_USAGE_CRITICAL=100 \
    FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=999 \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

run_guard_case_read_only() {
  local dir=$1
  FM_TMP_USAGE_WARN=100 FM_TMP_USAGE_HIGH=100 FM_TMP_USAGE_CRITICAL=100 \
    FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=999 \
    FM_GUARD_READ_ONLY=1 \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

# A `date` that reports the wall clock advanced by FM_TEST_CLOCK_SKEW seconds.
# The guard measures the outage as its own clock minus the beacon's mtime, so
# skewing the clock ages the outage without touching the beacon - and the
# episode key is the beacon's mtime, so the episode survives the skew. Only the
# bare `date +%s` the age arithmetic uses is intercepted; anything else runs
# real.
make_clock_bin() {  # <dir>
  local dir=$1 bin real
  bin="$dir/clockbin"
  if [ ! -x "$bin/date" ]; then
    real=$(command -v date)
    mkdir -p "$bin"
    {
      printf '#!/bin/sh\n'
      printf "real='%s'\n" "$real"
      cat <<'SHIM'
if [ "$#" -eq 1 ] && [ "$1" = "+%s" ]; then
  echo $(( $("$real" +%s) + ${FM_TEST_CLOCK_SKEW:-0} ))
else
  exec "$real" "$@"
fi
SHIM
    } > "$bin/date"
    chmod +x "$bin/date"
  fi
  printf '%s\n' "$bin"
}

# Escalation-ladder run: FM_GUARD_GRACE=0 makes any beacon stale, so the outage
# duration the guard reports is exactly the beacon's age, plus the clock skew
# this run hands it.
run_guard_case_ladder() {  # <dir> <ladder> <repeat> [clock-skew-seconds]
  local dir=$1 ladder=$2 repeat=$3 skew=${4:-0} clockbin
  clockbin=$(make_clock_bin "$dir")
  PATH="$clockbin:$PATH" \
    FM_TEST_CLOCK_SKEW="$skew" \
    FM_TMP_USAGE_WARN=100 FM_TMP_USAGE_HIGH=100 FM_TMP_USAGE_CRITICAL=100 \
    FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=0 \
    FM_GUARD_ESCALATE_LADDER="$ladder" \
    FM_GUARD_ESCALATE_REPEAT="$repeat" \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

count_text() {
  local haystack=$1 needle=$2
  awk -v needle="$needle" 'index($0, needle) { c++ } END { print c + 0 }' <<EOF
$haystack
EOF
}

# Portable mtime helpers: GNU `touch -d` and BSD `touch -A` disagree, and the
# relative ages here have to be exact.
age_beacon() {  # <home> <seconds-ago>
  perl -e '
    my ($path, $ago) = @ARGV;
    open my $handle, ">>", $path or die "open: $!";
    close $handle;
    my $stamp = time - $ago;
    utime $stamp, $stamp, $path or die "utime: $!";
  ' "$1/state/.last-watcher-beat" "$2"
}

episode_key_of() {  # <home>
  awk 'NR == 1 { print $1 }' "$1/state/.guard-watcher-stale-banner" 2>/dev/null
}

test_first_stale_call_prints_full_banner() {
  local dir out
  dir=$(make_guard_case first-stale)
  out=$(run_guard_case "$dir")
  [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first stale guard call did not print exactly one full banner: $out"
  assert_contains "$out" "Trust the emitted supervision protocol" \
    "full banner must keep the actionable watcher-repair instruction"
  assert_contains "$out" "WILL still run" \
    "full banner must keep the guarded-operation continuation line"
  pass "fm-guard stale banner: first stale call prints the full actionable banner"
}

test_repeated_same_episode_prints_reminder_only() {
  local dir out1 out2 marker lines
  dir=$(make_guard_case repeated-stale)
  out1=$(run_guard_case "$dir")
  out2=$(run_guard_case "$dir")
  [ "$(count_text "$out1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first stale call did not print the full banner: $out1"
  [ "$(count_text "$out2" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 0 ] \
    || fail "second stale call repeated the full banner: $out2"
  assert_contains "$out2" "full banner already printed at this escalation level" \
    "second stale call did not print the concise reminder"
  marker="$(case_home "$dir")/state/.guard-watcher-stale-banner"
  assert_present "$marker" "stale banner marker was not written under the owning home"
  lines=$(awk 'END { print NR + 0 }' "$marker")
  [ "$lines" -le 1 ] || fail "stale banner marker must stay bounded to one line, got $lines"
  pass "fm-guard stale banner: repeated same-episode calls print a concise reminder only"
}

test_healthy_recovery_rearms_next_stale_episode() {
  local dir home out1 healthy out2
  dir=$(make_guard_case healthy-recovery)
  home=$(case_home "$dir")
  out1=$(run_guard_case "$dir")
  [ "$(count_text "$out1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first stale episode did not print the full banner: $out1"

  touch "$home/state/.last-watcher-beat"
  healthy=$(run_guard_case "$dir")
  [ -z "$healthy" ] || fail "guard should be silent after watcher recovery, got: $healthy"
  assert_absent "$home/state/.guard-watcher-stale-banner" \
    "healthy recovery must clear the stale-banner marker"

  rm -f "$home/state/.last-watcher-beat"
  out2=$(run_guard_case "$dir")
  [ "$(count_text "$out2" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "second stale episode did not re-print the full banner: $out2"
  pass "fm-guard stale banner: healthy recovery rearms the next stale episode"
}

test_concurrent_same_episode_prints_one_full_banner() {
  local dir out_dir i pids pid all full reminders
  dir=$(make_guard_case concurrent-stale)
  out_dir="$dir/outs"
  mkdir -p "$out_dir"
  pids=
  i=1
  while [ "$i" -le 30 ]; do
    (
      run_guard_case "$dir" > "$out_dir/$i.out" 2>&1
    ) &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || fail "concurrent guard subprocess failed"
  done
  all=$(cat "$out_dir"/*.out)
  full=$(count_text "$all" "WATCHER DOWN - SUPERVISION IS OFF")
  reminders=$(count_text "$all" "full banner already printed at this escalation level")
  [ "$full" -eq 1 ] || fail "concurrent same-episode calls printed $full full banners"$'\n'"$all"
  [ "$reminders" -eq 29 ] || fail "concurrent same-episode calls printed $reminders reminders, expected 29"$'\n'"$all"
  pass "fm-guard stale banner: concurrent same-episode calls claim exactly one full banner"
}

# Rungs and skews are minutes apart on purpose. The guard reads its own clock,
# so crossing a rung by sleeping real seconds against a one-second ladder raced
# the second each call happened to land on: a first call delayed past the
# second boundary already measured a 1s outage and claimed rung 1, and the
# later assertions then read the wrong side of the boundary. Every call below
# sits hundreds of seconds inside one band instead, so no scheduling delay can
# move it to another rung.
test_lengthening_outage_reprints_full_banner() {
  local dir home key_first key_last out
  dir=$(make_guard_case escalating-outage)
  home=$(case_home "$dir")
  # One beacon, never touched again: the episode key cannot change, so every
  # re-print below is caused by the outage getting LONGER, not by a new episode.
  age_beacon "$home" 0

  out=$(run_guard_case_ladder "$dir" "300 900" 3600 0)
  [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first stale call did not print the full banner: $out"
  printf '%s\n' "$out" | grep -Eq 'WATCHER DOWN - SUPERVISION IS OFF - down for [0-9]+s' \
    || fail "full banner must state the outage duration: $out"
  key_first=$(episode_key_of "$home")
  [ -n "$key_first" ] || fail "first full banner did not record an episode key"

  out=$(run_guard_case_ladder "$dir" "300 900" 3600 0)
  [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 0 ] \
    || fail "same escalation level repeated the full banner: $out"
  assert_contains "$out" "full banner already printed at this escalation level" \
    "same escalation level did not print the concise reminder"

  out=$(run_guard_case_ladder "$dir" "300 900" 3600 450)
  [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "crossing the first ladder rung did not re-print the full banner: $out"

  out=$(run_guard_case_ladder "$dir" "300 900" 3600 700)
  [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 0 ] \
    || fail "a duration between rungs re-printed the full banner: $out"

  out=$(run_guard_case_ladder "$dir" "300 900" 3600 1200)
  [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "crossing the second ladder rung did not re-print the full banner: $out"

  # Past the last rung the repeat interval keeps the alarm coming, so a long
  # outage never falls silent the way mtime-keyed suppression made it.
  out=$(run_guard_case_ladder "$dir" "300 900" 3600 4800)
  [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "outage past the last ladder rung stopped re-printing the full banner: $out"

  key_last=$(episode_key_of "$home")
  [ "$key_last" = "$key_first" ] \
    || fail "escalation changed the episode key ('$key_first' -> '$key_last'); re-prints must come from duration alone"
  pass "fm-guard stale banner: a lengthening outage re-claims the full banner on the escalation ladder"
}

# Upgrade path: a marker written by an older firstmate records only the episode
# key. With no beacon either, nothing dates the outage, so the guard has to
# escalate once and persist an anchor rather than sitting at rung 0 forever.
test_legacy_bare_key_marker_escalates_once_then_settles() {
  local dir home marker out1 out2 since
  dir=$(make_guard_case legacy-bare-key-marker)
  home=$(case_home "$dir")
  marker="$home/state/.guard-watcher-stale-banner"
  rm -f "$home/state/.last-watcher-beat"
  printf 'beat:absent\n' > "$marker"

  out1=$(run_guard_case "$dir")
  [ "$(count_text "$out1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "a legacy bare-key marker suppressed the full banner instead of escalating once: $out1"
  since=$(awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i ~ /^since=[0-9]+$/) print $i }' "$marker")
  [ -n "$since" ] \
    || fail "escalating from a legacy bare-key marker did not persist an outage anchor: $(cat "$marker")"

  out2=$(run_guard_case "$dir")
  [ "$(count_text "$out2" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 0 ] \
    || fail "an upgraded marker repeated the full banner at the same escalation level: $out2"
  assert_contains "$out2" "full banner already printed at this escalation level" \
    "an upgraded marker did not settle onto the concise reminder"
  pass "fm-guard stale banner: a legacy bare-key marker escalates once and then settles onto the ladder"
}

test_banner_states_outage_duration() {
  local dir home out
  dir=$(make_guard_case outage-duration)
  home=$(case_home "$dir")

  out=$(run_guard_case "$dir")
  assert_contains "$out" "down for an unknown time" \
    "a never-seen beacon must be reported as an unknown-length outage, not a zero-length one"

  age_beacon "$home" 90
  out=$(run_guard_case_ladder "$dir" "300 900 3600" 3600)
  assert_contains "$out" "down for 1m" "banner must state a minutes-scale outage duration"

  age_beacon "$home" 7500
  out=$(run_guard_case_ladder "$dir" "300 900 3600" 3600)
  assert_contains "$out" "down for 2h 5m" "banner must state an hours-scale outage duration"
  pass "fm-guard stale banner: every alarm states how long supervision has been down"
}

test_home_isolation() {
  local dir_a dir_b out_a1 out_a2 out_b1
  dir_a=$(make_guard_case home-a)
  dir_b=$(make_guard_case home-b)
  out_a1=$(run_guard_case "$dir_a")
  out_b1=$(run_guard_case "$dir_b")
  out_a2=$(run_guard_case "$dir_a")
  [ "$(count_text "$out_a1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "home A first stale call did not print a full banner: $out_a1"
  [ "$(count_text "$out_b1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "home B first stale call was suppressed by home A: $out_b1"
  assert_contains "$out_a2" "full banner already printed at this escalation level" \
    "home A repeated stale call did not remember its own episode"
  pass "fm-guard stale banner: deduplication is isolated per FM_HOME"
}

test_queued_wake_warning_stays_independent() {
  local dir home out1 out2
  dir=$(make_guard_case queued-wake)
  home=$(case_home "$dir")
  out1=$(run_guard_case "$dir")
  [ "$(count_text "$out1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first stale call did not print the full banner before queued wake case: $out1"
  printf 'signal: %s/state/task.status\n' "$home" > "$home/state/.wake-queue"
  out2=$(run_guard_case "$dir")
  assert_contains "$out2" "full banner already printed at this escalation level" \
    "same-episode stale call should still print its concise reminder"
  assert_contains "$out2" "queued wakes pending" \
    "queued wake warning must not be suppressed by stale-banner deduplication"
  pass "fm-guard stale banner: queued-wake warning remains independent"
}

test_read_only_before_writable_does_not_consume_full_banner() {
  local dir home marker lock out_ro out_rw
  dir=$(make_guard_case read-only-before-writable)
  home=$(case_home "$dir")
  marker="$home/state/.guard-watcher-stale-banner"
  lock="$home/state/.guard-watcher-stale-banner.lock"

  out_ro=$(run_guard_case_read_only "$dir")
  [ "$(count_text "$out_ro" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "read-only stale call should print the advisory full banner: $out_ro"
  assert_absent "$marker" "read-only stale call must not create the stale-banner marker"
  assert_absent "$lock" "read-only stale call must not create the stale-banner lock"

  out_rw=$(run_guard_case "$dir")
  [ "$(count_text "$out_rw" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "writable stale call should still receive the full banner after read-only: $out_rw"
  assert_present "$marker" "writable stale call should claim the stale-banner marker"
  pass "fm-guard stale banner: read-only before writable does not consume full banner"
}

test_read_only_during_episode_observes_without_mutating_marker() {
  local dir home marker before after out_ro
  dir=$(make_guard_case read-only-during-episode)
  home=$(case_home "$dir")
  marker="$home/state/.guard-watcher-stale-banner"

  run_guard_case "$dir" >/dev/null
  before=$(cat "$marker")
  out_ro=$(run_guard_case_read_only "$dir")
  after=$(cat "$marker")
  assert_contains "$out_ro" "full banner already printed at this escalation level" \
    "read-only stale call during a claimed episode should print the concise reminder"
  [ "$after" = "$before" ] || fail "read-only stale call must not update an existing marker"
  pass "fm-guard stale banner: read-only during episode observes without mutating marker"
}

test_healthy_read_only_does_not_clear_marker() {
  local dir home marker before after healthy
  dir=$(make_guard_case healthy-read-only)
  home=$(case_home "$dir")
  marker="$home/state/.guard-watcher-stale-banner"

  run_guard_case "$dir" >/dev/null
  before=$(cat "$marker")
  touch "$home/state/.last-watcher-beat"
  healthy=$(run_guard_case_read_only "$dir")
  [ -z "$healthy" ] || fail "healthy read-only guard should stay silent, got: $healthy"
  assert_present "$marker" "healthy read-only guard must not clear the stale-banner marker"
  after=$(cat "$marker")
  [ "$after" = "$before" ] || fail "healthy read-only guard must not update the marker"
  pass "fm-guard stale banner: healthy read-only does not clear marker"
}

test_read_only_never_mutates_stale_banner_state_files() {
  local dir home marker lock before after no_work
  dir=$(make_guard_case read-only-state-nonmutation)
  home=$(case_home "$dir")
  marker="$home/state/.guard-watcher-stale-banner"
  lock="$home/state/.guard-watcher-stale-banner.lock"
  printf '%s\n' "sentinel-marker" > "$marker"

  before=$(find "$home/state" -maxdepth 1 -mindepth 1 -name '.guard-watcher-stale-banner*' -print | sort)
  run_guard_case_read_only "$dir" >/dev/null
  after=$(find "$home/state" -maxdepth 1 -mindepth 1 -name '.guard-watcher-stale-banner*' -print | sort)
  [ "$after" = "$before" ] || fail "stale read-only guard changed stale-banner state files"$'\n'"before: $before"$'\n'"after: $after"
  [ "$(cat "$marker")" = "sentinel-marker" ] || fail "stale read-only guard updated the marker content"
  assert_absent "$lock" "stale read-only guard must not create the stale-banner lock"

  rm -f "$home/state/task.meta"
  no_work=$(run_guard_case_read_only "$dir")
  [ -z "$no_work" ] || fail "read-only guard with no in-flight work should stay silent, got: $no_work"
  after=$(find "$home/state" -maxdepth 1 -mindepth 1 -name '.guard-watcher-stale-banner*' -print | sort)
  [ "$after" = "$before" ] || fail "no-work read-only guard changed stale-banner state files"$'\n'"before: $before"$'\n'"after: $after"
  [ "$(cat "$marker")" = "sentinel-marker" ] || fail "no-work read-only guard updated the marker content"
  pass "fm-guard stale banner: read-only never mutates stale-banner state files"
}

test_first_stale_call_prints_full_banner
test_repeated_same_episode_prints_reminder_only
test_healthy_recovery_rearms_next_stale_episode
test_concurrent_same_episode_prints_one_full_banner
test_lengthening_outage_reprints_full_banner
test_legacy_bare_key_marker_escalates_once_then_settles
test_banner_states_outage_duration
test_home_isolation
test_queued_wake_warning_stays_independent
test_read_only_before_writable_does_not_consume_full_banner
test_read_only_during_episode_observes_without_mutating_marker
test_healthy_read_only_does_not_clear_marker
test_read_only_never_mutates_stale_banner_state_files
