#!/usr/bin/env bash
# Tests for bin/fm-quality-event.sh: appends one quality-streak event to a
# mate's ledger, recomputes the decayed running total, and publishes the
# three-token readout to the mate's own herdr Space.
#
# Fake-herdr-CLI unit tests (mirrors tests/fm-herdr-outcome-publish.test.sh's
# fakebin/command-log convention): a `herdr` stub that logs every invocation
# and exits with a configurable code, so assertions are on what got called,
# never on the script's implementation bytes.
#
# Matrix:
#   (a) valid call appends exactly one JSONL line with the expected fields
#   (b) score matches report.md section E's worked examples (#40, live pass,
#       attribution correction)
#   (c) severity guard caps a stated S1 to S2 for catch_before_land
#   (d) severity guard floors a stated S3/S4 to S2 for merged_broken and
#       silent_code_loss
#   (e) an unstated severity defaults to S3, never S1
#   (f) the decayed total clamps at a floor of -20
#   (g) a herdr-backed mate publishes exactly three tokens: streak,
#       streak_hl, sev
#   (h) a non-severity event publishes sev=-
#   (i) a mate with no meta still gets its ledger line, no herdr call
#   (j) a non-herdr mate: no herdr call
#   (k) herdr meta present but missing session/workspace fields: no herdr call
#   (l) invalid event/size/severity/mate id: usage error, exit 2, no ledger
#       write
#   (m) wrong argument count: usage error, exit 2
#   (n) the herdr CLI itself failing never fails the script
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by fm-quality-event.sh)"; exit 0; }

SUBJECT="$ROOT/bin/fm-quality-event.sh"
TMP_ROOT=$(fm_test_tmproot fm-quality-event-tests)

# Build a fresh sandbox: data/state dirs plus a fakebin with a herdr stub that
# logs every invocation ("HERDR_SESSION=<val> ARGS=<args>", one line per call)
# to $case_dir/herdr.log and exits 0 unless $case_dir/herdr-exit overrides it.
# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/data" "$case_dir/state" "$fakebin"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf 'HERDR_SESSION=%s ARGS=%s\n' "${HERDR_SESSION:-}" "$*" >> "${FM_TEST_HERDR_LOG:?}"
exit "$(cat "${FM_TEST_HERDR_EXIT_FILE:?}" 2>/dev/null || echo 0)"
SH
  chmod +x "$fakebin/herdr"
  : > "$case_dir/herdr.log"
  printf '0\n' > "$case_dir/herdr-exit"
  printf '%s\n' "$case_dir"
}

write_herdr_meta() {
  local case_dir=$1 mate=$2
  fm_write_meta "$case_dir/state/$mate.meta" \
    "window=fmtest:w1:p2" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=secondmate" \
    "backend=herdr" \
    "herdr_session=fmtest" \
    "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t2" \
    "herdr_pane_id=w1:p2"
}

run_event() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_HERDR_LOG="$case_dir/herdr.log" \
  FM_TEST_HERDR_EXIT_FILE="$case_dir/herdr-exit" \
  PATH="$case_dir/fakebin:$PATH" \
    "$SUBJECT" "$@"
}

ledger_path() {
  printf '%s/data/quality-ledger/%s.jsonl' "$1" "$2"
}

test_valid_call_appends_one_line() {
  local case_dir rc ledger
  case_dir=$(make_case append-one-line)
  ledger=$(ledger_path "$case_dir" mate1)

  set +e
  run_event "$case_dir" mate1 task_completed M - "shipped it" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "append: should succeed"
  [ -f "$ledger" ] || fail "append: ledger file was not created"
  [ "$(wc -l < "$ledger" | tr -d '[:space:]')" = 1 ] || fail "append: expected exactly one ledger line"
  assert_grep '"event":"task_completed"' "$ledger" "append: event field missing"
  assert_grep '"size":"M"' "$ledger" "append: size field missing"
  assert_grep '"note":"shipped it"' "$ledger" "append: note field missing"
  assert_grep '"score":2.0000' "$ledger" "append: task_completed M should score base 2 x size 1.00"
  pass "fm-quality-event appends exactly one JSONL line with the expected fields"
}

decayed_total() {
  local ledger=$1 now=$2
  jq -r '[.ts, .score, .hl] | @tsv' "$ledger" | awk -F'\t' -v now="$now" '
    { hl=$3; if (hl<=0) { total+=$2; next } d=(now-$1)/86400.0; total += $2*(2^(-(d/hl))) }
    END { if (total < -20) total=-20; printf "%.2f", total }
  '
}

test_worked_example_pr40() {
  local case_dir rc ledger now total
  case_dir=$(make_case worked-example-pr40)
  ledger=$(ledger_path "$case_dir" shipper)

  set +e
  run_event "$case_dir" shipper reported_done_false - - "reported done while conflicted" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  run_event "$case_dir" shipper silent_code_loss - S2 "rebase deleted #39" \
    >> "$case_dir/stdout" 2>> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "pr40: should succeed"
  now=$(date +%s)
  total=$(decayed_total "$ledger" "$now")
  [ "$total" = "-20.00" ] || fail "pr40: expected the floored total -20.00, got $total"
  pass "fm-quality-event reproduces report.md example E-1 (PR #40): floors at -20.00"
}

test_worked_example_live_pass() {
  local case_dir ledger now total
  case_dir=$(make_case worked-example-live-pass)
  ledger=$(ledger_path "$case_dir" liveverifier)

  {
    run_event "$case_dir" liveverifier live_verification L - "live pass"
    run_event "$case_dir" liveverifier catch_before_land - S3 "double-draw found"
    run_event "$case_dir" liveverifier pr_merged L - "merged green"
    run_event "$case_dir" liveverifier task_completed L - "no forced rework"
  } > "$case_dir/stdout" 2> "$case_dir/stderr"

  now=$(date +%s)
  total=$(decayed_total "$ledger" "$now")
  [ "$total" = "23.75" ] || fail "live-pass: expected +23.75 per report.md example E-2, got $total"
  pass "fm-quality-event reproduces report.md example E-2 (live pass catch): +23.75"
}

test_worked_example_attribution_correction() {
  local case_dir ledger now total
  case_dir=$(make_case worked-example-attribution)
  ledger=$(ledger_path "$case_dir" scout)

  run_event "$case_dir" scout attribution_corrected - S2 "PR27 proven innocent" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  run_event "$case_dir" scout task_completed M - "bisection done, no rework" \
    >> "$case_dir/stdout" 2>> "$case_dir/stderr"

  now=$(date +%s)
  total=$(decayed_total "$ledger" "$now")
  [ "$total" = "12.00" ] || fail "attribution: expected +12.00 per report.md example E-3, got $total"
  pass "fm-quality-event reproduces report.md example E-3 (attribution corrected): +12.00"
}

test_severity_guard_caps_catch_before_land() {
  local case_dir ledger
  case_dir=$(make_case guard-cap)
  ledger=$(ledger_path "$case_dir" guarded)

  run_event "$case_dir" guarded catch_before_land - S1 "stated too high" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"

  assert_grep '"severity":"S2"' "$ledger" "guard-cap: catch_before_land S1 should be capped to S2"
  assert_grep '"score":16.0000' "$ledger" "guard-cap: capped severity should score base 8 x S2 (2.0)"
  pass "fm-quality-event caps a stated S1 to S2 for catch_before_land"
}

test_severity_guard_floors_merged_broken_and_silent_loss() {
  local case_dir ledger
  case_dir=$(make_case guard-floor)
  ledger=$(ledger_path "$case_dir" guarded2)

  run_event "$case_dir" guarded2 merged_broken - S4 "stated too low" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  run_event "$case_dir" guarded2 silent_code_loss - S3 "stated too low" \
    >> "$case_dir/stdout" 2>> "$case_dir/stderr"

  assert_grep '"event":"merged_broken","size":"-","severity":"S2"' "$ledger" \
    "guard-floor: merged_broken S4 should be floored to S2"
  assert_grep '"event":"silent_code_loss","size":"-","severity":"S2"' "$ledger" \
    "guard-floor: silent_code_loss S3 should be floored to S2"
  pass "fm-quality-event floors a stated S3/S4 to S2 for merged_broken and silent_code_loss"
}

test_unstated_severity_defaults_to_s3_never_s1() {
  local case_dir ledger
  case_dir=$(make_case guard-unstated)
  ledger=$(ledger_path "$case_dir" guarded3)

  run_event "$case_dir" guarded3 attribution_corrected - - "no statement given" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"

  assert_grep '"severity":"S3"' "$ledger" "guard-unstated: an unstated severity should default to S3"
  assert_no_grep '"severity":"S1"' "$ledger" "guard-unstated: an unstated severity must never resolve to S1"
  pass "fm-quality-event defaults an unstated severity to S3, never S1"
}

test_herdr_mate_publishes_exactly_three_tokens() {
  local case_dir rc calls token_count
  case_dir=$(make_case herdr-three-tokens)
  write_herdr_meta "$case_dir" mate9

  set +e
  run_event "$case_dir" mate9 catch_before_land - S3 "double-draw found" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "three-tokens: publish should succeed"
  calls=$(grep -c 'report-metadata' "$case_dir/herdr.log" || true)
  [ "$calls" = 1 ] || fail "three-tokens: expected exactly one report-metadata call, got $calls"
  assert_grep 'streak=' "$case_dir/herdr.log" "three-tokens: streak token missing"
  assert_grep 'streak_hl=5/10' "$case_dir/herdr.log" "three-tokens: streak_hl token should be 5/10"
  assert_grep 'sev=S3' "$case_dir/herdr.log" "three-tokens: sev token should carry the guarded severity"
  token_count=$(grep -o -- '--token' "$case_dir/herdr.log" | wc -l | tr -d '[:space:]')
  [ "$token_count" = 3 ] || fail "three-tokens: expected exactly 3 --token flags, got $token_count"
  pass "fm-quality-event publishes exactly three metadata tokens: streak, streak_hl, sev"
}

test_non_severity_event_publishes_sev_dash() {
  local case_dir
  case_dir=$(make_case sev-dash)
  write_herdr_meta "$case_dir" mate10

  run_event "$case_dir" mate10 pr_merged M - "merged green" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"

  assert_grep 'sev=-' "$case_dir/herdr.log" "sev-dash: a non-severity event should publish sev=-"
  pass "fm-quality-event publishes sev=- for an event with no severity concept"
}

test_no_meta_still_writes_ledger_no_herdr_call() {
  local case_dir rc ledger
  case_dir=$(make_case no-meta)
  ledger=$(ledger_path "$case_dir" mate11)

  set +e
  run_event "$case_dir" mate11 honest_limitation - - "flagged a gap" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-meta: should succeed"
  [ -s "$ledger" ] || fail "no-meta: ledger line should still be written"
  [ ! -s "$case_dir/herdr.log" ] || fail "no-meta: herdr was called with no meta present"
  pass "fm-quality-event writes the ledger even when the mate has no meta, without calling herdr"
}

test_non_herdr_mate_publishes_nothing() {
  local case_dir
  case_dir=$(make_case non-herdr)
  fm_write_meta "$case_dir/state/mate12.meta" \
    "window=firstmate:fm-mate12" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=secondmate"

  run_event "$case_dir" mate12 task_completed S - "done" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"

  [ ! -s "$case_dir/herdr.log" ] || fail "non-herdr: herdr was called for a non-herdr mate"
  pass "fm-quality-event is a silent no-op toward herdr for a non-herdr mate"
}

test_missing_session_fields_publishes_nothing() {
  local case_dir
  case_dir=$(make_case missing-fields)
  fm_write_meta "$case_dir/state/mate13.meta" \
    "window=fmtest:w1:p2" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=secondmate" \
    "backend=herdr"

  run_event "$case_dir" mate13 task_completed S - "done" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"

  [ ! -s "$case_dir/herdr.log" ] || fail "missing-fields: herdr was called with no resolvable session/workspace"
  pass "fm-quality-event is a silent no-op toward herdr when session/workspace fields are absent"
}

test_invalid_inputs_are_usage_errors() {
  local case_dir rc ledger

  case_dir=$(make_case invalid-event)
  ledger=$(ledger_path "$case_dir" matex)
  set +e
  run_event "$case_dir" matex bogus_event M S1 note > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "invalid-event: an unknown event should be refused"
  assert_grep 'usage:' "$case_dir/stderr" "invalid-event: refusal did not explain usage"
  [ ! -f "$ledger" ] || fail "invalid-event: ledger should not be written on a usage error"

  case_dir=$(make_case invalid-size)
  set +e
  run_event "$case_dir" matex task_completed XL - note > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "invalid-size: an unknown size should be refused"

  case_dir=$(make_case invalid-severity)
  set +e
  run_event "$case_dir" matex task_completed M S5 note > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "invalid-severity: an unknown severity should be refused"

  case_dir=$(make_case invalid-mate-id)
  set +e
  run_event "$case_dir" "bad id" task_completed M - note > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "invalid-mate-id: an unsafe mate id should be refused"

  pass "fm-quality-event refuses an unknown event, size, severity, or unsafe mate id as a usage error"
}

test_wrong_arg_count_is_a_usage_error() {
  local case_dir rc
  case_dir=$(make_case wrong-arg-count)

  set +e
  run_event "$case_dir" mate14 task_completed M \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "wrong-arg-count: a missing note argument should be refused"
  assert_grep 'usage:' "$case_dir/stderr" "wrong-arg-count: refusal did not explain usage"
  pass "fm-quality-event refuses a call with the wrong argument count"
}

test_herdr_cli_failure_never_fails_the_script() {
  local case_dir rc ledger
  case_dir=$(make_case cli-failure)
  write_herdr_meta "$case_dir" mate15
  printf '1\n' > "$case_dir/herdr-exit"
  ledger=$(ledger_path "$case_dir" mate15)

  set +e
  run_event "$case_dir" mate15 task_completed S - "done" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "cli-failure: a failing herdr CLI call should never fail the script"
  [ -s "$ledger" ] || fail "cli-failure: the ledger should still be written"
  assert_grep 'report-metadata' "$case_dir/herdr.log" "cli-failure: report-metadata was not attempted"
  pass "fm-quality-event never fails when the underlying herdr CLI call fails"
}

test_valid_call_appends_one_line
test_worked_example_pr40
test_worked_example_live_pass
test_worked_example_attribution_correction
test_severity_guard_caps_catch_before_land
test_severity_guard_floors_merged_broken_and_silent_loss
test_unstated_severity_defaults_to_s3_never_s1
test_herdr_mate_publishes_exactly_three_tokens
test_non_severity_event_publishes_sev_dash
test_no_meta_still_writes_ledger_no_herdr_call
test_non_herdr_mate_publishes_nothing
test_missing_session_fields_publishes_nothing
test_invalid_inputs_are_usage_errors
test_wrong_arg_count_is_a_usage_error
test_herdr_cli_failure_never_fails_the_script
