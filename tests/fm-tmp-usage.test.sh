#!/usr/bin/env bash
# Behavior tests for fm-tmp-usage.sh, the cheap pressure check on the shared
# temp filesystem.
#
# The check exists because a near-full temp root does not announce itself: temp
# writes fail, commands come back empty, and it reads as a broken agent. So the
# cases that matter are the ones proving it actually SEES that condition and
# says so - and that it keeps working under the same conditions, because a check
# that only survives on a healthy filesystem is worthless on a full one:
#   - it reports the real filesystem's real numbers, agreeing with df itself
#   - it detects a genuinely near-full filesystem and grades the severity
#   - it never shells out to du, whose whole-tree walk is exactly what was
#     observed hanging or aborting on the near-full root
#   - it writes nothing, so it still runs against a root with no space and no
#     write permission
#   - it reports an unmeasurable root as unknown rather than passing quietly
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tmp-usage)
# fm_test_tmproot runs in a command substitution, whose own EXIT trap removes
# the directory as that subshell ends; every fixture path here is created
# explicitly, and this suite measures the root itself, so recreate it.
mkdir -p "$TMP_ROOT"
CHECK="$ROOT/bin/fm-tmp-usage.sh"

# run_check [args...]: run the check with a neutral environment so nothing the
# suite's own shell exports can decide the outcome.
run_check() {
  env -u FM_TMP_USAGE_ROOT -u FM_TMP_USAGE_WARN -u FM_TMP_USAGE_HIGH \
    -u FM_TMP_USAGE_CRITICAL "$CHECK" "$@" 2>&1
}

# fake_df_root <name> <df-line>: a fakebin dir whose df prints exactly one
# fabricated filesystem, so a near-full filesystem can be exercised on a host
# that has plenty of space.
fake_df_root() {
  local name=$1 line=$2 dir fakebin
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf %%s\\\\n "Filesystem     1024-blocks      Used Available Capacity Mounted on"\n'
    printf 'printf %%s\\\\n %q\n' "$line"
  } > "$fakebin/df"
  chmod +x "$fakebin/df"
  printf '%s\n' "$fakebin"
}

# --- it agrees with df about a real filesystem -------------------------------
#
# No fake anything: the check must report the same capacity for a real path that
# df reports for it, or every threshold below is measuring a fiction.

real_line=$(df -Pk "$TMP_ROOT" | awk 'NR > 1 && NF >= 5 { last = $0 } END { print last }')
read -r _fs _total _used _avail real_cap _rest <<<"$real_line"
real_pct=${real_cap%\%}
case "$real_pct" in
  ''|*[!0-9]*) fail "could not read a real capacity from df for $TMP_ROOT" ;;
esac
[ "$real_pct" -lt 100 ] \
  || fail "the host temp filesystem is 100% full; free space before running this suite"

out=$(run_check --root "$TMP_ROOT" --verbose)
expect_code 0 $? "a filesystem below the warn threshold exits 0"
assert_contains "$out" "$real_pct% full" \
  "the check reports the same capacity df reports for the same path"
assert_contains "$out" "$TMP_ROOT: ok:" \
  "a healthy root reads as ok when asked verbosely"
pass "reports the real capacity of a real filesystem, agreeing with df"

# Below the warn threshold it must say nothing at all, so that silence in a
# session-start digest means measured-and-healthy.
out=$(run_check --root "$TMP_ROOT" --warn 100 --high 100 --critical 100)
expect_code 0 $? "a healthy root exits 0"
[ -z "$out" ] || fail "a healthy root must be silent, got: $out"
pass "stays silent below the warn threshold"

# --- it detects a near-full filesystem, and grades it ------------------------
#
# The df line here is the shape of a real RAM-backed /tmp with almost nothing
# left: 7.4G total, ~300M free. That is the condition that broke the session.

NEAR_FULL='tmpfs              7755232   7445372    309860      97% /tmp'
fakebin=$(fake_df_root near-full "$NEAR_FULL")

out=$(PATH="$fakebin:$PATH" run_check --root "$TMP_ROOT")
expect_code 12 $? "a 97%-full filesystem exits with the critical status"
assert_contains "$out" "critical:" "a 97%-full filesystem is critical"
assert_contains "$out" "97% full" "the critical line carries the real percentage"
assert_contains "$out" "303M free of 7.4G" \
  "the critical line carries free space in the units df -h shows"
pass "detects a near-full filesystem and reports it as critical"

# Severity has to be monotonic in fullness: the same filesystem read against
# progressively higher thresholds must never grade quieter than a fuller one.
out=$(PATH="$fakebin:$PATH" run_check --root "$TMP_ROOT" --warn 80 --high 90 --critical 98)
expect_code 11 $? "97% under a 98% critical threshold is high, not critical"
assert_contains "$out" "high:" "a filesystem past the high threshold reads as high"

out=$(PATH="$fakebin:$PATH" run_check --root "$TMP_ROOT" --warn 80 --high 98 --critical 99)
expect_code 10 $? "97% under a 98% high threshold is a warning"
assert_contains "$out" "warn:" "a filesystem past only the warn threshold reads as warn"

out=$(PATH="$fakebin:$PATH" run_check --root "$TMP_ROOT" --warn 98 --high 99 --critical 100)
expect_code 0 $? "97% under a 98% warn threshold is healthy"
[ -z "$out" ] || fail "a filesystem under every threshold must be silent, got: $out"
pass "grades warn, high, and critical monotonically as the filesystem fills"

# A filesystem that reports no capacity column still has to be graded, because
# refusing to grade it is indistinguishable from healthy.
fakebin_nocap=$(fake_df_root no-capacity \
  'tmpfs              7755232   7445372    309860       - /tmp')
out=$(PATH="$fakebin_nocap:$PATH" run_check --root "$TMP_ROOT")
expect_code 12 $? "a filesystem with no capacity column is still graded from its blocks"
assert_contains "$out" "97% full" \
  "capacity computed from used and available matches what df would report"
pass "grades a filesystem whose df reports no capacity column"

# --- it must not depend on anything that fails on a full filesystem ----------
#
# du -sh on the whole tree was observed hanging or aborting on the near-full
# root. A check that calls it inherits that failure exactly when it is needed.

dudir="$TMP_ROOT/no-du"
mkdir -p "$dudir"
du_fakebin=$(fm_fakebin "$dudir")
SENTINEL="$dudir/du-was-called"
cat > "$du_fakebin/du" <<SH
#!/usr/bin/env bash
printf 'called\n' > "$SENTINEL"
exit 1
SH
chmod +x "$du_fakebin/du"

out=$(PATH="$du_fakebin:$fakebin:$PATH" run_check --root "$TMP_ROOT")
expect_code 12 $? "the check still grades a near-full filesystem with du broken"
assert_contains "$out" "critical:" "a broken du does not change the reported severity"
assert_absent "$SENTINEL" "the check must never invoke du"
pass "works with du broken, and never calls it"

# The other half of the same requirement: the check must not need to write. A
# root with no space has no room for a temp file, and a root that is read-only
# would refuse one.
rodir="$TMP_ROOT/readonly"
mkdir -p "$rodir"
before=$(find "$rodir" | sort)
chmod 500 "$rodir"
out=$(run_check --root "$rodir" --verbose)
rc=$?
chmod 700 "$rodir"
expect_code 0 "$rc" "a read-only root is still measurable"
assert_contains "$out" "$rodir: ok:" "a read-only root reports its real usage"
after=$(find "$rodir" | sort)
[ "$before" = "$after" ] || fail "the check wrote into the root it measured: $after"
pass "measures a root it cannot write to, and leaves nothing behind"

# --- an unmeasurable root is unknown, never healthy --------------------------

out=$(run_check --root "$TMP_ROOT/does-not-exist")
expect_code 3 $? "a missing root exits with the unknown status"
assert_contains "$out" "unknown:" "a missing root reports unknown"
assert_not_contains "$out" "ok:" "a missing root never reads as healthy"

nodf_dir="$TMP_ROOT/no-df"
mkdir -p "$nodf_dir"
nodf_fakebin=$(fm_fakebin "$nodf_dir")
cat > "$nodf_fakebin/df" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$nodf_fakebin/df"
out=$(PATH="$nodf_fakebin:$PATH" run_check --root "$TMP_ROOT")
expect_code 3 $? "a df that fails exits with the unknown status"
assert_contains "$out" "unknown:" "a failing df reports unknown rather than silence"
pass "reports an unmeasurable root as unknown rather than passing quietly"

# --- misconfiguration is refused, not silently reordered ---------------------
#
# Out-of-order thresholds would break the monotonicity proved above, so they are
# an error rather than something the check quietly sorts.

out=$(run_check --root "$TMP_ROOT" --warn 95 --high 90 --critical 99)
expect_code 1 $? "a warn threshold above the high threshold is refused"
assert_contains "$out" "must not exceed" "the refusal names the conflicting thresholds"

out=$(run_check --root "$TMP_ROOT" --warn 0)
expect_code 1 $? "a zero percentage is refused"

out=$(run_check --root "$TMP_ROOT" --warn abc)
expect_code 1 $? "a non-numeric percentage is refused"
pass "refuses thresholds that would break severity ordering"

# --- the environment overrides drive the same behavior -----------------------
#
# bin/fm-guard.sh and bin/fm-bootstrap.sh call the check with no arguments, so
# the env form has to be equivalent to the flags.

out=$(FM_TMP_USAGE_ROOT="$TMP_ROOT" FM_TMP_USAGE_WARN=1 FM_TMP_USAGE_HIGH=100 \
  FM_TMP_USAGE_CRITICAL=100 "$CHECK" 2>&1)
expect_code 10 $? "the env form grades the same filesystem the same way"
assert_contains "$out" "$TMP_ROOT: warn:" "the env form measures the root it was given"
pass "the environment overrides drive the same grading as the flags"

# --- how loud the guard makes each severity ----------------------------------
#
# The check only measures; bin/fm-guard.sh decides volume, on the fleet actions
# that matter. The incident's failure mode was nobody being told, so the
# properties that matter are that pressure is never silent and that a filesystem
# which keeps filling gets LOUDER rather than being deduplicated into silence.
#
# Severity is forced by moving the thresholds around the fixture root's real
# usage, so the guard is driven by a real measurement of a real filesystem.
[ "$real_pct" -ge 1 ] \
  || fail "the fixture filesystem reports 0% used; this suite cannot force a severity on it"

GUARD_HOME="$TMP_ROOT/guard/home"
GUARD_ROOT="$TMP_ROOT/guard/root"
GUARD_MARKER="$GUARD_HOME/state/.guard-tmp-usage-banner"
mkdir -p "$GUARD_HOME/state" "$GUARD_HOME/config" "$GUARD_ROOT"

# run_guard <warn> <high> <critical> [extra env assignments...]
run_guard() {
  local warn=$1 high=$2 critical=$3
  shift 3
  env FM_ROOT_OVERRIDE="$GUARD_ROOT" FM_HOME="$GUARD_HOME" \
    FM_TMP_USAGE_ROOT="$TMP_ROOT" \
    FM_TMP_USAGE_WARN="$warn" FM_TMP_USAGE_HIGH="$high" FM_TMP_USAGE_CRITICAL="$critical" \
    "$@" "$ROOT/bin/fm-guard.sh" 2>&1
}

out=$(run_guard "$real_pct" 100 100)
assert_contains "$out" "temp filesystem filling up" \
  "the first severity is reported, not swallowed"
assert_not_contains "$out" "●" "the lowest severity stays a single line, not a banner"
assert_absent "$GUARD_MARKER" "the lowest severity claims no banner episode"
pass "guard reports the first severity as one line"

out=$(run_guard "$real_pct" "$real_pct" 100)
assert_contains "$out" "TEMP FILESYSTEM NEARLY FULL" \
  "a higher severity claims the full banner"
assert_contains "$out" "fm-tmp-sweep.sh" \
  "the banner names the one thing that reclaims space"
assert_contains "$out" "never delete them automatically" \
  "the banner says what must not be reclaimed automatically"
assert_present "$GUARD_MARKER" "the claimed severity is recorded"

out=$(run_guard "$real_pct" "$real_pct" 100)
assert_not_contains "$out" "TEMP FILESYSTEM NEARLY FULL" \
  "an unchanged severity does not re-print the whole banner"
assert_contains "$out" "still under pressure" \
  "an unchanged severity still says the pressure has not gone away"
pass "guard claims the banner once per severity, then keeps a reminder"

# The property the incident turned on: getting worse must get louder.
out=$(run_guard "$real_pct" "$real_pct" "$real_pct")
assert_contains "$out" "TEMP FILESYSTEM CRITICALLY FULL" \
  "climbing to a higher severity re-claims the banner, louder than before"
[ "$(cat "$GUARD_MARKER")" = "3" ] || fail "the new, higher severity is the one recorded"

out=$(run_guard "$real_pct" "$real_pct" "$real_pct")
assert_not_contains "$out" "TEMP FILESYSTEM CRITICALLY FULL" \
  "the highest severity also settles to a reminder once claimed"
assert_contains "$out" "still under pressure" "the highest severity is never fully silent"
pass "guard gets louder as the filesystem fills further"

out=$(run_guard 100 100 100)
assert_not_contains "$out" "temp filesystem" "a healthy temp root is silent"
assert_absent "$GUARD_MARKER" \
  "recovering ends the episode so a later climb re-claims the banner"

out=$(run_guard "$real_pct" "$real_pct" 100)
assert_contains "$out" "TEMP FILESYSTEM NEARLY FULL" \
  "a later climb after recovery claims the banner again"
pass "guard re-arms after the pressure clears"

# A read-only session must still be told, and must record nothing.
rm -f "$GUARD_MARKER"
out=$(run_guard "$real_pct" "$real_pct" 100 FM_GUARD_READ_ONLY=1)
assert_contains "$out" "TEMP FILESYSTEM NEARLY FULL" \
  "a read-only session is still warned about temp pressure"
assert_contains "$out" "report the pressure, not reclaim space" \
  "a read-only session is told to report rather than reclaim"
assert_absent "$GUARD_MARKER" "a read-only session records no episode state"
pass "guard warns a read-only session without recording state"

# Unmeasurable must never read as healthy on the guard path either.
out=$(env FM_ROOT_OVERRIDE="$GUARD_ROOT" FM_HOME="$GUARD_HOME" \
  FM_TMP_USAGE_ROOT="$TMP_ROOT/does-not-exist" "$ROOT/bin/fm-guard.sh" 2>&1)
assert_contains "$out" "could not measure" \
  "a temp root the guard cannot measure is reported, not assumed healthy"
pass "guard reports an unmeasurable temp root rather than staying silent"
