#!/usr/bin/env bash
# Contract tests for bin/fm-test-run.sh - the single owner of behavior suite
# selection, portable lane composition, proven-isolated --jobs, timing markers,
# JSON artifacts, coverage guard, and aggregate exit status.
#
# These tests intentionally exercise the runner with fixtures, --list, and
# focused scheduler checks, not the complete Firstmate suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-test-run.sh"

assert_present "$RUNNER" "bin/fm-test-run.sh is missing"
[ -x "$RUNNER" ] || fail "bin/fm-test-run.sh must be executable"

test_list_all_exact_suite_coverage() {
  local listed expected missing extra f
  listed=$("$RUNNER" --list --all | LC_ALL=C sort)
  expected=$(
    for f in "$ROOT"/tests/*.test.sh; do
      [ -f "$f" ] || continue
      printf 'tests/%s\n' "$(basename "$f")"
    done | LC_ALL=C sort
  )
  [ -n "$listed" ] || fail "--list --all printed nothing"
  missing=$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  extra=$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  [ -z "$missing" ] || fail "--list --all missing scripts: $missing"
  [ -z "$extra" ] || fail "--list --all unexpected scripts: $extra"
  # No duplicates.
  [ "$(printf '%s\n' "$listed" | uniq | wc -l | tr -d ' ')" = \
    "$(printf '%s\n' "$listed" | wc -l | tr -d ' ')" ] \
    || fail "--list --all must not duplicate scripts"
  pass "exact suite coverage: --all lists every tests/*.test.sh once"
}

test_family_selection() {
  local listed line
  listed=$("$RUNNER" --list --family pure-contract-unit)
  [ -n "$listed" ] || fail "--family pure-contract-unit selected nothing"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-test-run.test.sh' \
    || fail "pure-contract-unit must include fm-test-run.test.sh"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      tests/*.test.sh) ;;
      *) fail "family selection produced non-test path: $line" ;;
    esac
  done <<<"$listed"
  # Family mode must not equal the complete suite for a narrow family.
  local all_count fam_count
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] \
    || fail "pure-contract-unit must be a proper subset of --all"
  pass "family selection returns a proper subset of the suite"
}

test_single_script_selection() {
  local listed
  listed=$("$RUNNER" --list tests/fm-lint.test.sh)
  [ "$listed" = "tests/fm-lint.test.sh" ] \
    || fail "single-script list expected tests/fm-lint.test.sh, got: $listed"
  pass "single-script selection lists exactly that path"
}

test_changed_file_selection_is_conservative() {
  local listed all_count fam_count listed_count
  # A path-mapped pure unit should not expand to --all.
  listed=$("$RUNNER" --list --family pure-contract-unit)
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] || fail "changed-informed pure family still full suite"
  # Directly exercise --changed: empty or partial selection is ok; must not
  # exceed the suite and must never silently become --all by accident.
  listed=$("$RUNNER" --list --changed --base HEAD 2>/dev/null || true)
  if [ -n "$listed" ]; then
    listed_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
    [ "$listed_count" -le "$all_count" ] || fail "changed selection larger than suite"
  fi
  # A single test path selects only that script (same contract as a
  # tests/*.test.sh change entry in the map).
  listed=$("$RUNNER" --list tests/fm-brief.test.sh)
  [ "$listed" = "tests/fm-brief.test.sh" ] \
    || fail "test-file-only change contract should select one script"
  pass "changed-file selection stays conservative (never silent full suite)"
}

init_changed_fixture_repo() {
  local repo=$1 script
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  for script in \
    fm-brief.test.sh \
    fm-ask-user-authority.test.sh \
    fm-cd-pretool-check.test.sh \
    fm-daemon.test.sh \
    fm-backend-herdr-smoke.test.sh \
    fm-secondmate-safety.test.sh \
    fm-session-start.test.sh \
    fm-afk-pi-herdr-return-e2e.test.sh \
    fm-backend.test.sh \
    fm-pr-merge.test.sh \
    fm-pi-watch-extension.test.sh \
    fm-afk-return.test.sh \
    fm-bearings-snapshot.test.sh \
    fm-backend-cmux.test.sh \
    fm-backend-zellij.test.sh \
    fm-backend-orca.test.sh; do
    printf '#!/usr/bin/env bash\n# tests/lib.sh\n' >"$repo/tests/$script"
    chmod +x "$repo/tests/$script"
  done
  : >"$repo/tests/lib.sh"
  : >"$repo/tests/fm-backend-herdr-eventwait.test.py"
  : >"$repo/bin/fm-supervisor-target-lib.sh"
  : >"$repo/bin/unmapped-source.sh"
  printf '# .claude/settings.json\n# .pi/extensions/fm-primary-turnend-guard.ts\n' \
    >>"$repo/tests/fm-cd-pretool-check.test.sh"
  printf '# .pi/extensions/fm-primary-pi-watch.ts\n' >>"$repo/tests/fm-pi-watch-extension.test.sh"
  mkdir -p "$repo/.agents/skills/example" "$repo/.claude" "$repo/.pi/extensions" "$repo/src"
  : >"$repo/.agents/skills/example/SKILL.md"
  : >"$repo/.claude/settings.json"
  : >"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : >"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  : >"$repo/src/unmapped.ts"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
}

test_changed_dependency_selection_and_unmapped_failure() {
  local tmp repo listed rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-changed.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  printf '\n' >>"$repo/tests/lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pr-merge.test.sh" "shared helper selects pr-forge dependents"
  assert_contains "$listed" "tests/fm-secondmate-safety.test.sh" "shared helper selects secondmate dependents"
  assert_contains "$listed" "tests/fm-bearings-snapshot.test.sh" "shared helper selects snapshot dependents"
  git -C "$repo" add tests/lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm helper-change

  printf '\n' >>"$repo/tests/fm-backend-herdr-eventwait.test.py"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend-herdr-smoke.test.sh" "eventwait test selects Herdr coverage"
  assert_contains "$listed" "tests/fm-backend.test.sh" "eventwait test selects backend coverage"
  git -C "$repo" add tests/fm-backend-herdr-eventwait.test.py
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm eventwait-change

  printf '\n' >>"$repo/bin/fm-supervisor-target-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-daemon.test.sh" "supervisor target selects daemon coverage"
  assert_contains "$listed" "tests/fm-afk-return.test.sh" "supervisor target selects afk coverage"
  git -C "$repo" add bin/fm-supervisor-target-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm supervisor-change

  printf '\n' >>"$repo/.agents/skills/example/SKILL.md"
  printf '\n' >>"$repo/.claude/settings.json"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-ask-user-authority.test.sh" "skill source selects pure contract coverage"
  assert_contains "$listed" "tests/fm-cd-pretool-check.test.sh" "Claude and Pi source selects hook coverage"
  assert_contains "$listed" "tests/fm-pi-watch-extension.test.sh" "Pi source selects watcher coverage"
  git -C "$repo" add .agents .claude .pi
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm non-bin-source-change

  printf '\n' >>"$repo/src/unmapped.ts"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unmapped changed source must fail with exit 2, got $rc"
  grep -Fq 'no changed-test mapping for source path: src/unmapped.ts' "$tmp/err" \
    || fail "unmapped changed source failure is not actionable: $(cat "$tmp/err")"
  rm -rf "$tmp"
  pass "changed selection covers dependents and fails closed for unmapped source"
}

test_empty_selection_emits_summary() {
  local tmp repo out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-empty.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  printf 'documentation only\n' >"$repo/README.md"
  out=$(cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --json "$tmp/artifacts/timing.json" 2>"$tmp/err") \
    || fail "empty valid changed selection must pass"
  [ "$out" = "FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=0" ] \
    || fail "empty selection summary is missing or non-deterministic: $out"
  json="$tmp/artifacts/timing.json"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["summary"] == {"duration_ms": 0, "failed": 0, "skipped_gate": 0, "total": 0}
assert doc["scripts"] == []
assert doc["families"] == []
' "$json" || { rm -rf "$tmp"; fail "empty selection JSON summary is wrong"; }
  rm -rf "$tmp"
  pass "empty changed selection emits deterministic text and JSON summaries"
}

test_timing_markers_and_json() {
  local tmp fixture out json begin_n end_n summary
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-timing.XXXXXX")
  fixture="$tmp/ok.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
echo "ok - fixture"
exit 0
SH
  chmod +x "$fixture"
  "$RUNNER" --json "$json" "$fixture" >"$out" 2>"$tmp/err.txt" \
    || { rm -rf "$tmp"; fail "runner should pass on a green fixture"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$out" || true)
  [ "$begin_n" -eq 1 ] || fail "expected one FM_TEST_BEGIN, got $begin_n"
  [ "$end_n" -eq 1 ] || fail "expected one FM_TEST_END, got $end_n"
  grep -Eq '^FM_TEST_BEGIN .+ family=unclassified expected_gate_skip=none$' "$out" \
    || fail "BEGIN line missing family/expected_gate_skip: $(grep '^FM_TEST_BEGIN' "$out")"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=false$' "$out" \
    || fail "END line missing exit/duration/gate_skip: $(grep '^FM_TEST_END' "$out")"
  summary=$(grep '^FM_TEST_SUMMARY ' "$out" || true)
  assert_contains "$summary" "total=1" "summary total"
  assert_contains "$summary" "failed=0" "summary failed"
  assert_contains "$summary" "skipped_gate=0" "summary skipped_gate"
  grep -q '^FM_TEST_SLOWEST rank=1 ' "$out" \
    || fail "expected FM_TEST_SLOWEST rank=1"
  [ -f "$json" ] || fail "JSON timing artifact was not written"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$json" \
    || fail "JSON timing artifact is not valid JSON"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert "scripts" in doc and len(doc["scripts"]) == 1, doc
assert doc["scripts"][0]["exit"] == 0
assert doc["scripts"][0]["gate_skip"] is False
assert doc["summary"]["total"] == 1
assert doc["summary"]["failed"] == 0
assert "duration_ms" in doc["scripts"][0]
assert "family" in doc["scripts"][0]
' "$json" || { rm -rf "$tmp"; fail "JSON timing artifact missing required fields"; }
  rm -rf "$tmp"
  pass "timing markers and JSON artifact are valid"
}

test_aggregate_exit_behavior() {
  local tmp pass_f fail_f rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-agg.XXXXXX")
  pass_f="$tmp/pass.test.sh"
  fail_f="$tmp/fail.test.sh"
  cat >"$pass_f" <<'SH'
#!/usr/bin/env bash
echo "ok - pass"
exit 0
SH
  cat >"$fail_f" <<'SH'
#!/usr/bin/env bash
echo "not ok - fail"
exit 1
SH
  chmod +x "$pass_f" "$fail_f"
  set +e
  "$RUNNER" "$pass_f" "$fail_f" >"$tmp/out.txt" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "aggregate exit must be non-zero when any script fails"
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out.txt" \
    || fail "summary should report total=2 failed=1: $(grep FM_TEST_SUMMARY "$tmp/out.txt")"
  # All-green stays 0.
  set +e
  "$RUNNER" "$pass_f" >"$tmp/out2.txt" 2>"$tmp/err2.txt"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { rm -rf "$tmp"; fail "aggregate exit must be 0 when every script passes"; }
  rm -rf "$tmp"
  pass "aggregate exit reflects any script failure"
}

test_gate_skip_accounting() {
  local tmp skip_f out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  "$RUNNER" --json "$json" "$skip_f" >"$out" 2>"$tmp/err.txt" \
    || fail "gate-skip fixture must exit 0 from the runner"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$out" \
    || fail "END must mark gate_skip=true: $(grep '^FM_TEST_END' "$out")"
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$out" \
    || fail "summary must count skipped_gate=1: $(grep FM_TEST_SUMMARY "$out")"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["scripts"][0]["gate_skip"] is True
assert doc["summary"]["skipped_gate"] == 1
assert doc["summary"]["failed"] == 0
' "$json" || { rm -rf "$tmp"; fail "JSON gate_skip accounting is wrong"; }
  rm -rf "$tmp"
  pass "gate-skip accounting is honest and non-failing"
}

test_fail_on_gate_skip_token() {
  local tmp skip_f out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-fail-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  set +e
  "$RUNNER" --fail-on-gate-skip 'herdr not found' "$skip_f" >"$out" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fail-on-gate-skip must make herdr-not-found a hard failure"
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$out" \
    || fail "summary must report failed=1 under fail-on-gate-skip: $(grep FM_TEST_SUMMARY "$out")"
  grep -q 'required gate skip token' "$tmp/err.txt" \
    || fail "runner must log the required gate skip token"
  rm -rf "$tmp"
  pass "fail-on-gate-skip converts herdr-not-found into a hard failure"
}

test_exclude_family() {
  local listed
  listed=$("$RUNNER" --list --all --exclude-family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "exclude-family real-herdr-gated left a real-herdr script"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-lint.test.sh' \
    || fail "exclude-family must retain pure-contract-unit scripts"
  # Explicit family mode still works; exclude of a different family is a no-op.
  listed=$("$RUNNER" --list --family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "family real-herdr-gated must list smoke test"
  pass "exclude-family drops the named primary family after selection"
}

test_portable_shard_union_and_coverage_guard() {
  local s1 s2 proven serial herdr all_count union_count overlap out first
  s1=$("$RUNNER" --list --lane portable-parallel-1)
  s2=$("$RUNNER" --list --lane portable-parallel-2)
  proven=$("$RUNNER" --list --proven-isolated)
  serial=$("$RUNNER" --list --lane portable-serial)
  herdr=$("$RUNNER" --list --family real-herdr-gated)
  [ -n "$s1" ] && [ -n "$s2" ] || fail "portable parallel shards must be non-empty"
  # Shards disjoint.
  overlap=$(comm -12 <(printf '%s\n' "$s1" | LC_ALL=C sort) <(printf '%s\n' "$s2" | LC_ALL=C sort) || true)
  [ -z "$overlap" ] || fail "portable parallel shards overlap: $overlap"
  # Union of shards equals proven-isolated.
  [ "$(printf '%s\n' "$s1" "$s2" | LC_ALL=C sort -u)" = \
    "$(printf '%s\n' "$proven" | LC_ALL=C sort -u)" ] \
    || fail "shard union must equal proven-isolated set"
  # No herdr in portable lanes.
  printf '%s\n' "$s1" "$s2" "$serial" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "portable lanes must not include real-herdr-gated smoke"
  printf '%s\n' "$herdr" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "herdr family must include smoke"
  out=$("$RUNNER" --check-coverage)
  assert_contains "$out" "FM_TEST_COVERAGE ok" "coverage guard success marker"
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  union_count=$(printf '%s\n' "$s1" "$s2" "$serial" "$herdr" | LC_ALL=C sort -u | wc -l | tr -d ' ')
  [ "$union_count" = "$all_count" ] \
    || fail "union of lanes ($union_count) must equal --all ($all_count)"
  # No duplicates across the four partitions.
  [ "$(printf '%s\n' "$s1" "$s2" "$serial" "$herdr" | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')" = "0" ] \
    || fail "lanes must not duplicate scripts"
  # LPT order: first script of shard 1 is the longest proven script.
  first=$(printf '%s\n' "$s1" | head -n 1)
  [ "$first" = "tests/fm-x-mode.test.sh" ] \
    || fail "shard 1 must start with the longest proven script, got $first"
  pass "portable shard union, disjointness, and coverage guard hold"
}

test_jobs_requires_proven_isolated() {
  local tmp rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs.XXXXXX")
  set +e
  "$RUNNER" --jobs 2 --lane portable-serial >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs with portable-serial must refuse (exit 2), got $rc"
  grep -Fq 'not in the proven-isolated set' "$tmp/err" \
    || fail "--jobs refusal message missing: $(cat "$tmp/err")"
  set +e
  "$RUNNER" --jobs 2 tests/fm-watcher-lock.test.sh >"$tmp/out2" 2>"$tmp/err2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs on watcher-lock must refuse, got $rc"
  rm -rf "$tmp"
  pass "--jobs refuses non-proven / stateful selections"
}

test_jobs_parallel_scheduler_and_failure_propagation() {
  local tmp repo runner evidence fake_bin a b c d rc begin_n end_n
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs-sched.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  evidence="$tmp/evidence"
  fake_bin="$tmp/fake-bin"
  a=tests/fm-brief.test.sh
  b=tests/fm-composer-lib.test.sh
  c=tests/fm-lint.test.sh
  d=tests/fm-supervision-instructions.test.sh
  mkdir -p "$repo/bin" "$repo/tests" "$evidence" "$fake_bin"
  cp "$RUNNER" "$runner"
  cat >"$fake_bin/stat" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$2" = "%a" ]; then
  printf '700\n'
  exit 0
fi
if [ "$1" = "-f" ] && [ "$2" = "%Lp" ]; then
  printf '  File: "%s"\n    ID: fake Namelen: 255 Type: ext2/ext3\n700\n' "$3"
  exit 0
fi
exit 1
SH
  cat >"$repo/$a" <<'SH'
#!/usr/bin/env bash
sleep 0.5
touch "$SCHED_EVIDENCE/slow-done"
echo "ok - slow fixture"
SH
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
sleep 0.05
echo "ok - fast fixture"
SH
  cat >"$repo/$c" <<'SH'
#!/usr/bin/env bash
if [ -e "$SCHED_EVIDENCE/slow-done" ]; then
  echo "not ok - scheduler waited for oldest worker"
  exit 1
fi
echo "ok - replacement fixture started before slow fixture finished"
SH
  chmod +x "$runner" "$repo/$a" "$repo/$b" "$repo/$c" "$fake_bin/stat"
  set +e
  PATH="$fake_bin:$PATH" SCHED_EVIDENCE="$evidence" \
    "$runner" --jobs 2 --json "$tmp/timing.json" \
    "$a" "$b" "$c" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "jobs=2 must refill the first completed slot"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$tmp/out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$tmp/out" || true)
  [ "$begin_n" -eq 3 ] || fail "expected 3 BEGIN markers, got $begin_n"
  [ "$end_n" -eq 3 ] || fail "expected 3 END markers, got $end_n"
  grep -q 'FM_TEST_SUMMARY total=3 failed=0' "$tmp/out" \
    || fail "summary missing for jobs run: $(grep FM_TEST_SUMMARY "$tmp/out")"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==0
assert "jobs=2" in doc["selection"]
' "$tmp/timing.json" || { rm -rf "$tmp"; fail "jobs JSON artifact wrong"; }

  # Non-proven path is refused before any worker starts (no race masking).
  cat >"$tmp/fail.test.sh" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate fail"
exit 1
SH
  chmod +x "$tmp/fail.test.sh"
  set +e
  "$runner" --jobs 2 "$a" "$tmp/fail.test.sh" >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "jobs with non-proven fail fixture must refuse before run, got $rc"

  # Parallel failure propagation stays inside the private runner fixture.
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate proven-set fail"
exit 1
SH
  chmod +x "$repo/$b"
  rm -f "$evidence/slow-done"
  set +e
  SCHED_EVIDENCE="$evidence" "$runner" --jobs 2 "$a" "$b" >"$tmp/out4" 2>"$tmp/err4"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "jobs aggregate must be non-zero when a proven worker fails"; }
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out4" \
    || { rm -rf "$tmp"; fail "jobs failure summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out4")"; }

  cat >"$repo/$d" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found" >&2
exit 0
SH
  chmod +x "$repo/$d"
  set +e
  "$runner" --jobs 2 --fail-on-gate-skip 'herdr not found' "$d" >"$tmp/out5" 2>"$tmp/err5"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "parallel stderr gate skip must hard-fail"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$tmp/out5" \
    || { rm -rf "$tmp"; fail "parallel stderr hard-fail summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out5")"; }

  "$runner" --jobs 2 "$d" >"$tmp/out6" 2>"$tmp/err6" \
    || { rm -rf "$tmp"; fail "ordinary parallel stderr gate skip must remain successful"; }
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr gate skip was not recorded"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr skip summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out6")"; }

  rm -rf "$tmp"
  pass "jobs scheduler runs proven scripts; failure propagates; non-proven refused"
}

test_aggregate_json() {
  local tmp a b
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-aggjson.XXXXXX")
  cat >"$tmp/a.json" <<'JSON'
{
  "run_id": "a",
  "selection": "lane=portable-parallel-1",
  "started_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:01:00Z",
  "summary": {"total": 1, "failed": 0, "skipped_gate": 0, "duration_ms": 1000},
  "scripts": [{"path": "tests/a.test.sh", "family": "pure-contract-unit", "duration_ms": 1000, "exit": 0, "gate_skip": false}]
}
JSON
  cat >"$tmp/b.json" <<'JSON'
{
  "run_id": "b",
  "selection": "lane=portable-serial",
  "started_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:02:00Z",
  "summary": {"total": 2, "failed": 1, "skipped_gate": 0, "duration_ms": 2000},
  "scripts": [
    {"path": "tests/b.test.sh", "family": "afk", "duration_ms": 1500, "exit": 1, "gate_skip": false},
    {"path": "tests/c.test.sh", "family": "afk", "duration_ms": 500, "exit": 0, "gate_skip": false}
  ]
}
JSON
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" "$tmp/a.json" "$tmp/b.json")
  assert_contains "$out" "FM_TEST_AGGREGATE lanes=2 total=3 failed=1" "aggregate summary line"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["kind"]=="aggregate"
assert doc["summary"]["lanes"]==2
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==1
assert doc["summary"]["critical_path_duration_ms"]==2000
assert len(doc["scripts"])==3
' "$tmp/out.json" || { rm -rf "$tmp"; fail "aggregate JSON shape wrong"; }
  rm -rf "$tmp"
  pass "aggregate-json merges lane timing artifacts"
}

# --- fixture containment and orphan reap ------------------------------------
#
# /tmp is a tmpfs on some hosts, so a fixture the suite leaves behind is leaked
# RAM. These exercise the runner's containment and reap through real runs: a
# probe script builds a fixture exactly the way the suite does, and the
# assertions are about what survives on disk afterwards.

# Write a test script that builds one fixture under TMPDIR, records its path to
# <record>, and then runs <trailer> (empty for a script that just exits).
write_fixture_probe() {
  local path=$1 record=$2 trailer=${3:-}
  cat >"$path" <<SH
#!/usr/bin/env bash
set -eu
probe=\$(mktemp -d "\${TMPDIR:-/tmp}/fm-probe.XXXXXX")
mkdir -p "\$probe/payload"
head -c 4096 /dev/zero >"\$probe/payload/blob"
printf '%s\n' "\$probe" >'$record'
echo "ok - probe built \$probe"
$trailer
SH
  chmod +x "$path"
}

# Runner invocation with the nested-run suppression cleared, so a reap actually
# runs even when this file is itself executing under the runner.
#
# Clearing that suppression means the reap runs for real, so every call site has
# to aim it at a fixture root. The host's /tmp holds scratch belonging to other
# live firstmate sessions, and reaping it as a side effect of running the suite
# would delete their work. Refusing here rather than defaulting keeps the next
# test that reaches for this helper from silently inheriting the real /tmp.
run_runner_unnested() {
  [ -n "${FM_TEST_REAP_ROOT:-}" ] \
    || fail "run_runner_unnested needs FM_TEST_REAP_ROOT aimed at a fixture root"
  env -u FM_TEST_RUN_ACTIVE "$RUNNER" "$@"
}

test_completed_run_leaves_no_fixture() {
  local tmp probe record fixture root
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-contain.XXXXXX")
  probe="$tmp/probe.test.sh"
  record="$tmp/fixture-path"
  mkdir -p "$tmp/reap"
  write_fixture_probe "$probe" "$record"
  FM_TEST_REAP_ROOT="$tmp/reap" \
    run_runner_unnested "$probe" >"$tmp/out" 2>"$tmp/err" \
    || fail "probe run should pass: $(cat "$tmp/err")"
  [ -s "$record" ] || fail "probe did not record its fixture path"
  fixture=$(cat "$record")
  case "$fixture" in
    /tmp/fm-probe.*) fail "fixture was built directly in /tmp, not inside the run: $fixture" ;;
  esac
  assert_absent "$fixture" "a completed run must leave no fixture behind: $fixture"
  # The run root that contained it is gone too, not just the fixture.
  root=$(dirname "$(dirname "$fixture")")
  assert_absent "$root" "a completed run must remove its own temp root: $root"
  rm -rf "$tmp"
  pass "a run that completes normally leaves no fixture behind"
}

test_fixture_removed_when_run_is_interrupted() {
  local tmp probe record fixture root pid waited
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-interrupt.XXXXXX")
  probe="$tmp/probe.test.sh"
  record="$tmp/fixture-path"
  mkdir -p "$tmp/reap"
  write_fixture_probe "$probe" "$record" 'sleep 120'
  # Monitor mode puts the background runner in its own process group, so the
  # signal reaches the runner and the test it is running together - the same
  # shape as a terminal interrupt, which is how the leak accumulated.
  set -m
  FM_TEST_REAP_ROOT="$tmp/reap" \
    run_runner_unnested "$probe" >"$tmp/out" 2>"$tmp/err" &
  pid=$!
  set +m
  waited=0
  while [ ! -s "$record" ]; do
    waited=$((waited + 1))
    [ "$waited" -lt 600 ] || { kill -KILL -- "-$pid" 2>/dev/null; fail "probe never built its fixture"; }
    sleep 0.1
  done
  fixture=$(cat "$record")
  assert_present "$fixture" "probe fixture should exist while the run is live"
  kill -INT -- "-$pid" 2>/dev/null || fail "could not interrupt the run"
  wait "$pid" 2>/dev/null || true
  waited=0
  while [ -e "$fixture" ]; do
    waited=$((waited + 1))
    [ "$waited" -lt 100 ] || fail "an interrupted run left its fixture behind: $fixture"
    sleep 0.1
  done
  root=$(dirname "$(dirname "$fixture")")
  assert_absent "$root" "an interrupted run must remove its own temp root: $root"
  rm -rf "$tmp"
  pass "a run interrupted mid-way leaves no fixture behind"
}

test_spawned_task_scratch_is_contained() {
  local tmp probe record scratch
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-taskscratch.XXXXXX")
  probe="$tmp/probe.test.sh"
  record="$tmp/scratch-path"
  # Mirrors what bin/fm-spawn.sh does for a task: a per-task root with gotmp/
  # nested inside it, rooted at FM_TASK_TMP_ROOT. A test that drives a real spawn
  # would otherwise strand this under /tmp with no task and no teardown.
  cat >"$probe" <<SH
#!/usr/bin/env bash
set -eu
[ -n "\${FM_TASK_TMP_ROOT:-}" ] || { echo "not ok - runner did not set FM_TASK_TMP_ROOT"; exit 1; }
scratch="\$FM_TASK_TMP_ROOT/fm-probe-task"
mkdir -p "\$scratch/gotmp"
printf '%s\n' "\$scratch" >'$record'
echo "ok - task scratch at \$scratch"
SH
  chmod +x "$probe"
  mkdir -p "$tmp/reap"
  FM_TEST_REAP_ROOT="$tmp/reap" \
    run_runner_unnested "$probe" >"$tmp/out" 2>"$tmp/err" \
    || fail "probe run should pass: $(cat "$tmp/err")"
  [ -s "$record" ] || fail "probe did not record its task scratch root"
  scratch=$(cat "$record")
  assert_absent "/tmp/fm-probe-task" "task scratch must never be stranded in /tmp"
  assert_absent "$scratch" "a completed run must remove the task scratch it created: $scratch"
  rm -rf "$tmp"
  pass "a task scratch root created during a run is contained and removed"
}

test_killed_run_is_healed_by_the_next_run() {
  local tmp scratch probe record fixture root out pid waited
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-killed.XXXXXX")
  scratch="$tmp/scratch"
  mkdir -p "$scratch" "$tmp/reap"
  probe="$tmp/probe.test.sh"
  record="$tmp/fixture-path"
  write_fixture_probe "$probe" "$record" 'sleep 120'
  # SIGKILL runs no trap at all. This is exactly how the leak accumulated, so
  # the run root must survive the kill and then be reaped by the next run.
  set -m
  TMPDIR="$scratch" FM_TEST_REAP_ROOT="$tmp/reap" \
    run_runner_unnested "$probe" >"$tmp/out" 2>"$tmp/err" &
  pid=$!
  set +m
  waited=0
  while [ ! -s "$record" ]; do
    waited=$((waited + 1))
    [ "$waited" -lt 600 ] || { kill -KILL -- "-$pid" 2>/dev/null; fail "probe never built its fixture"; }
    sleep 0.1
  done
  fixture=$(cat "$record")
  kill -KILL -- "-$pid" 2>/dev/null || fail "could not kill the run"
  wait "$pid" 2>/dev/null || true
  assert_present "$fixture" "a killed run cannot clean up after itself"
  root=$(dirname "$(dirname "$fixture")")
  printf '#!/usr/bin/env bash\necho "ok - probe"\n' >"$tmp/plain.test.sh"
  chmod +x "$tmp/plain.test.sh"
  out=$(FM_TEST_REAP_ROOT="$scratch" FM_TEST_REAP_MIN_AGE_SECONDS=0 \
    run_runner_unnested "$tmp/plain.test.sh" 2>"$tmp/err2") \
    || fail "healing run should pass: $(cat "$tmp/err2")"
  assert_contains "$out" "removed=1" "the next run should reap the killed run's root: $out"
  assert_absent "$root" "a killed run's root must be reaped by the next run: $root"
  assert_absent "$fixture" "the killed run's fixture must be gone with its root: $fixture"
  rm -rf "$tmp"
  pass "a killed run's fixtures are reaped by the next run"
}

# Backstop for the looping worker fixtures below, so a failing assertion cannot
# strand them. Targets the run's own process group by PID rather than a command
# name, which cannot reach a process this test did not start. Always succeeds:
# an already-empty group is the expected outcome.
reap_stray_workers() {
  local pid=$1
  kill -KILL -- "-$pid" 2>/dev/null || true
  return 0
}

test_signalled_jobs_run_stops_its_workers() {
  local tmp repo runner reap runtmp a b f pid waited live leftover
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs-signal.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  reap="$tmp/reap"
  runtmp="$tmp/runtmp"
  a=tests/fm-brief.test.sh
  b=tests/fm-composer-lib.test.sh
  mkdir -p "$repo/bin" "$repo/tests" "$reap" "$runtmp"
  cp "$RUNNER" "$runner"
  chmod +x "$runner"
  # Each worker script keeps rebuilding a directory under its own TMPDIR, so a
  # child still running when the run root is removed recreates that root - the
  # orphan this runner exists to prevent, and the one a signal aimed at the
  # runner alone used to produce.
  for f in "$a" "$b"; do
    # shellcheck disable=SC2016 # $TMPDIR must be expanded by the worker, not here.
    printf '#!/usr/bin/env bash\nwhile :; do mkdir -p "$TMPDIR/live"; sleep 0.05; done\n' \
      >"$repo/$f"
    chmod +x "$repo/$f"
  done
  # Monitor mode only so the run owns a process group this test can clean up by
  # PID. The signal below still goes to the runner PID alone, never the group -
  # that is the case a supervisor or `timeout` produces, and the one where the
  # workers used to outlive the removal of their TMPDIR.
  set -m
  TMPDIR="$runtmp" FM_TEST_REAP_ROOT="$reap" \
    env -u FM_TEST_RUN_ACTIVE "$runner" --jobs 2 "$a" "$b" >"$tmp/out" 2>"$tmp/err" &
  pid=$!
  set +m
  waited=0
  live=
  while [ -z "$live" ]; do
    for f in "$runtmp"/fm-test-run.*/w*/tmp/live; do
      [ -d "$f" ] || continue
      live=$f
      break
    done
    [ -n "$live" ] && break
    waited=$((waited + 1))
    if [ "$waited" -ge 600 ]; then
      kill -KILL "$pid" 2>/dev/null || true
      reap_stray_workers "$pid"
      rm -rf "$tmp"
      fail "workers never started under --jobs"
    fi
    sleep 0.1
  done
  kill -TERM "$pid" 2>/dev/null || fail "could not signal the run"
  wait "$pid" 2>/dev/null || true
  # Long enough for any child that outlived the runner to rebuild what the
  # removal took away.
  sleep 1
  leftover=$(ls -A "$runtmp" 2>/dev/null || true)
  reap_stray_workers "$pid"
  if [ -n "$leftover" ]; then
    rm -rf "$tmp"
    fail "a signalled --jobs run left its run root behind: $leftover"
  fi
  rm -rf "$tmp"
  pass "a signalled --jobs run stops its workers before removing the run root"
}

test_aborted_jobs_run_stops_its_workers() {
  local tmp repo runner reap runtmp fakebin started real_chmod a b c f pid rc leftover
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs-abort.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  reap="$tmp/reap"
  runtmp="$tmp/runtmp"
  fakebin="$tmp/fakebin"
  started="$tmp/started"
  a=tests/fm-brief.test.sh
  b=tests/fm-composer-lib.test.sh
  c=tests/fm-crew-state.test.sh
  mkdir -p "$repo/bin" "$repo/tests" "$reap" "$runtmp" "$fakebin" "$started"
  cp "$RUNNER" "$runner"
  chmod +x "$runner"
  # Same worker shape as the signalled case: each keeps rebuilding a directory
  # under its own TMPDIR, so a child still running when the run root is removed
  # recreates that root. Each also announces itself outside the run root, so a
  # run that aborted before any worker started cannot pass this vacuously.
  for f in "$a" "$b" "$c"; do
    cat >"$repo/$f" <<SH
#!/usr/bin/env bash
: >"$started/\$(basename "\$0")"
while :; do mkdir -p "\$TMPDIR/live"; sleep 0.05; done
SH
    chmod +x "$repo/$f"
  done
  # An abort that is not a signal: the third worker root's chmod fails, which is
  # a plain \`|| die\` while the first two workers are already in flight. A full
  # tmpfs - the failure mode this whole change exists for - produces exactly
  # this. The delay gives the running workers time to announce themselves first.
  real_chmod=$(command -v chmod)
  cat >"$fakebin/chmod" <<SH
#!/usr/bin/env bash
last=
for arg in "\$@"; do last=\$arg; done
case "\$last" in
  */w3/tmp) sleep 1; exit 1 ;;
esac
exec "$real_chmod" "\$@"
SH
  chmod +x "$fakebin/chmod"
  # Monitor mode only so this test can clean up the run's process group by PID.
  set -m
  PATH="$fakebin:$PATH" TMPDIR="$runtmp" FM_TEST_REAP_ROOT="$reap" \
    env -u FM_TEST_RUN_ACTIVE "$runner" --jobs 3 "$a" "$b" "$c" \
    >"$tmp/out" 2>"$tmp/err" &
  pid=$!
  set +m
  wait "$pid" && rc=0 || rc=$?
  # Long enough for any child that outlived the runner to rebuild what the
  # removal took away.
  sleep 1
  leftover=$(ls -A "$runtmp" 2>/dev/null || true)
  reap_stray_workers "$pid"
  if [ "$rc" -eq 0 ]; then
    rm -rf "$tmp"
    fail "a failed worker root setup must abort the run"
  fi
  if [ -z "$(ls -A "$started" 2>/dev/null || true)" ]; then
    rm -rf "$tmp"
    fail "no worker ever started, so the abort proved nothing"
  fi
  if [ -n "$leftover" ]; then
    rm -rf "$tmp"
    fail "an aborted --jobs run left its run root behind: $leftover"
  fi
  rm -rf "$tmp"
  pass "a --jobs run aborting without a signal stops its workers before removing the run root"
}

# Build an isolated reap root plus a Firstmate home whose recorded task scratch
# lives inside it. Echoes "<reap root>|<home>".
init_reap_fixture() {
  local tmp=$1 reap home
  reap="$tmp/reap"
  home="$tmp/home"
  mkdir -p "$reap" "$home/state"
  printf '%s|%s\n' "$reap" "$home"
}

# One aged, fixture-shaped directory inside the reap root.
# The reap refuses a tree with any recent write anywhere inside it, not just a
# recent top-level mtime, so an orphan fixture has to be aged out all the way
# down. Deepest paths first: writing or stamping a child restamps its parent.
make_orphan() {
  local reap=$1 name=$2
  mkdir -p "$reap/$name/payload"
  head -c 2048 /dev/zero >"$reap/$name/payload/blob"
  touch -t 200001010000 "$reap/$name/payload/blob" "$reap/$name/payload" "$reap/$name"
  printf '%s\n' "$reap/$name"
}

test_reap_clears_pre_existing_orphans() {
  local tmp reap home orphan fresh recent probe out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-reap.XXXXXX")
  IFS='|' read -r reap home <<<"$(init_reap_fixture "$tmp")"
  orphan=$(make_orphan "$reap" "fm-secondmate-safety.Ab12Cd")
  fresh="$reap/fm-recent-run.Zz99Yy"
  mkdir -p "$fresh"
  # Twenty minutes old. The runner takes the sweep's own conservative window
  # rather than shortening it, because this root is shared with other live
  # firstmate tooling whose scratch can sit unwritten for far longer than a test
  # fixture - bin/fm-home-seed.sh's rollback backup waits out a whole clone.
  # A genuinely leaked fixture is days old, so nothing is lost by waiting.
  recent="$reap/fm-seed-backup.Bb22Cc"
  mkdir -p "$recent"
  touch -d '20 minutes ago' "$recent" 2>/dev/null || touch -A -002000 "$recent"
  probe="$tmp/probe.test.sh"
  printf '#!/usr/bin/env bash\necho "ok - probe"\n' >"$probe"
  chmod +x "$probe"
  out=$(FM_TEST_REAP_ROOT="$reap" FM_TEST_REAP_HOMES="$home" \
    run_runner_unnested "$probe" 2>"$tmp/err") \
    || fail "reap run should pass: $(cat "$tmp/err")"
  assert_contains "$out" "FM_TEST_REAP root=$reap" "reap marker missing"
  assert_contains "$out" "removed=1" "reap should report the one removed orphan: $out"
  assert_absent "$orphan" "a pre-existing orphan must be reaped: $orphan"
  assert_present "$fresh" "a fixture younger than the minimum age must be kept: $fresh"
  assert_present "$recent" \
    "the runner must not shorten the sweep's age window for other tooling's scratch: $recent"
  rm -rf "$tmp"
  pass "a later run reaps pre-existing orphans and spares recent ones"
}

test_reap_never_touches_a_live_task_scratch() {
  local tmp reap home tasktmp gotmp probe out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-reap-task.XXXXXX")
  IFS='|' read -r reap home <<<"$(init_reap_fixture "$tmp")"
  # Fixture-shaped on purpose: only the recorded tasktmp= can save it.
  tasktmp=$(make_orphan "$reap" "fm-livetask.Qq77Rr")
  fm_write_meta "$home/state/livetask.meta" \
    "window=firstmate:fm-livetask" \
    "worktree=$home/wt" \
    "project=alpha" \
    "tasktmp=$tasktmp"
  # A per-task scratch root is also recognisable by its gotmp/ child.
  gotmp=$(make_orphan "$reap" "fm-othertask.Ss88Tt")
  mkdir -p "$gotmp/gotmp"
  touch -t 200001010000 "$gotmp"
  probe="$tmp/probe.test.sh"
  printf '#!/usr/bin/env bash\necho "ok - probe"\n' >"$probe"
  chmod +x "$probe"
  out=$(FM_TEST_REAP_ROOT="$reap" FM_TEST_REAP_HOMES="$home" \
    run_runner_unnested "$probe" 2>"$tmp/err") \
    || fail "reap run should pass: $(cat "$tmp/err")"
  assert_contains "$out" "removed=0" "no directory should have been removed: $out"
  assert_present "$tasktmp" "a live task's recorded scratch must never be removed: $tasktmp"
  assert_present "$tasktmp/payload/blob" "a live task's scratch contents must be intact"
  assert_present "$gotmp" "a per-task scratch root must never be removed: $gotmp"
  rm -rf "$tmp"
  pass "the reap never touches a live task's scratch directory"
}

test_reap_never_removes_a_held_open_fixture() {
  local tmp reap home held probe out holder waited
  if [ ! -r /proc/self/fd ] && ! command -v lsof >/dev/null 2>&1; then
    pass "held-open fixtures: no in-use inventory on this host, nothing to assert"
    return 0
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-reap-open.XXXXXX")
  IFS='|' read -r reap home <<<"$(init_reap_fixture "$tmp")"
  held=$(make_orphan "$reap" "fm-watcher-lock-tests.Uu66Vv")
  : >"$held/payload/handle"
  bash -c 'exec 7<"$1"; printf ready >"$2"; sleep 120' _ "$held/payload/handle" "$tmp/holder-ready" &
  holder=$!
  waited=0
  while [ ! -s "$tmp/holder-ready" ]; do
    waited=$((waited + 1))
    [ "$waited" -lt 600 ] || { kill "$holder" 2>/dev/null; fail "holder never opened the fixture"; }
    sleep 0.1
  done
  probe="$tmp/probe.test.sh"
  printf '#!/usr/bin/env bash\necho "ok - probe"\n' >"$probe"
  chmod +x "$probe"
  out=$(FM_TEST_REAP_ROOT="$reap" FM_TEST_REAP_HOMES="$home" \
    run_runner_unnested "$probe" 2>"$tmp/err") \
    || { kill "$holder" 2>/dev/null; fail "reap run should pass: $(cat "$tmp/err")"; }
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  assert_contains "$out" "removed=0" "a held-open fixture must not be removed: $out"
  assert_present "$held" "a directory another process holds open must be kept: $held"
  rm -rf "$tmp"
  pass "the reap never removes a fixture another process still holds open"
}

test_reap_stays_within_fm_fixture_names() {
  local tmp reap home probe out plain file nosuffix link target
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-reap-scope.XXXXXX")
  IFS='|' read -r reap home <<<"$(init_reap_fixture "$tmp")"
  plain="$reap/unrelated.Ab12Cd"
  nosuffix="$reap/fm-plainname"
  file="$reap/fm-a-file.Ab12Cd"
  target="$tmp/link-target"
  link="$reap/fm-symlink.Ab12Cd"
  mkdir -p "$plain" "$nosuffix" "$target"
  : >"$file"
  ln -s "$target" "$link"
  touch -t 200001010000 "$plain" "$nosuffix" "$file" "$target"
  probe="$tmp/probe.test.sh"
  printf '#!/usr/bin/env bash\necho "ok - probe"\n' >"$probe"
  chmod +x "$probe"
  out=$(FM_TEST_REAP_ROOT="$reap" FM_TEST_REAP_HOMES="$home" \
    run_runner_unnested "$probe" 2>"$tmp/err") \
    || fail "reap run should pass: $(cat "$tmp/err")"
  assert_contains "$out" "removed=0" "nothing outside the fixture shape may be removed: $out"
  assert_present "$plain" "a non-fm- name must never be considered: $plain"
  assert_present "$nosuffix" "an fm- name without an mktemp suffix must be kept: $nosuffix"
  assert_present "$file" "a plain file must be kept: $file"
  assert_present "$link" "a symlink must be kept: $link"
  assert_present "$target" "a symlink's target must never be followed: $target"
  rm -rf "$tmp"
  pass "the reap only considers mktemp-shaped fm- directories in its own root"
}

test_reap_is_suppressed_inside_a_nested_run() {
  local tmp reap home orphan probe out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-reap-nested.XXXXXX")
  IFS='|' read -r reap home <<<"$(init_reap_fixture "$tmp")"
  orphan=$(make_orphan "$reap" "fm-nested.Ww55Xx")
  probe="$tmp/probe.test.sh"
  printf '#!/usr/bin/env bash\necho "ok - probe"\n' >"$probe"
  chmod +x "$probe"
  out=$(FM_TEST_RUN_ACTIVE=1 FM_TEST_REAP_ROOT="$reap" FM_TEST_REAP_HOMES="$home" \
    "$RUNNER" "$probe" 2>"$tmp/err") \
    || fail "nested run should pass: $(cat "$tmp/err")"
  assert_not_contains "$out" "FM_TEST_REAP" "a nested run must not reap"
  assert_present "$orphan" "a nested run must leave orphans to its parent: $orphan"
  rm -rf "$tmp"
  pass "the reap is suppressed inside a nested run"
}

test_reap_refuses_when_task_records_cannot_be_read() {
  local tmp reap home orphan probe out
  if [ "$(id -u)" = 0 ]; then
    pass "unreadable task records: root bypasses directory permissions, nothing to assert"
    return 0
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-reap-unreadable.XXXXXX")
  IFS='|' read -r reap home <<<"$(init_reap_fixture "$tmp")"
  orphan=$(make_orphan "$reap" "fm-unreadable.Yy44Zz")
  chmod 000 "$home/state"
  probe="$tmp/probe.test.sh"
  printf '#!/usr/bin/env bash\necho "ok - probe"\n' >"$probe"
  chmod +x "$probe"
  out=$(FM_TEST_REAP_ROOT="$reap" FM_TEST_REAP_HOMES="$home" \
    run_runner_unnested "$probe" 2>"$tmp/err") \
    || { chmod 755 "$home/state"; fail "run should still pass: $(cat "$tmp/err")"; }
  chmod 755 "$home/state"
  assert_not_contains "$out" "FM_TEST_REAP" "an unreadable task record must stop the reap entirely"
  assert_present "$orphan" "nothing may be removed when task records cannot be read: $orphan"
  rm -rf "$tmp"
  pass "the reap refuses entirely when a home's task records cannot be read"
}

test_list_all_exact_suite_coverage
test_family_selection
test_single_script_selection
test_changed_file_selection_is_conservative
test_changed_dependency_selection_and_unmapped_failure
test_empty_selection_emits_summary
test_timing_markers_and_json
test_aggregate_exit_behavior
test_gate_skip_accounting
test_fail_on_gate_skip_token
test_exclude_family
test_portable_shard_union_and_coverage_guard
test_jobs_requires_proven_isolated
test_jobs_parallel_scheduler_and_failure_propagation
test_aggregate_json
test_completed_run_leaves_no_fixture
test_fixture_removed_when_run_is_interrupted
test_spawned_task_scratch_is_contained
test_killed_run_is_healed_by_the_next_run
test_signalled_jobs_run_stops_its_workers
test_aborted_jobs_run_stops_its_workers
test_reap_clears_pre_existing_orphans
test_reap_never_touches_a_live_task_scratch
test_reap_never_removes_a_held_open_fixture
test_reap_stays_within_fm_fixture_names
test_reap_is_suppressed_inside_a_nested_run
test_reap_refuses_when_task_records_cannot_be_read
