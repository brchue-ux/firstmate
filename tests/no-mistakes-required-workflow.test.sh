#!/usr/bin/env bash
# Behavior tests for the "Require no-mistakes" PR-body compliance check
# (.github/workflows/no-mistakes-required.yml).
#
# The check used to read only github.event.pull_request.body - a snapshot taken
# when the event fired. no-mistakes opens the PR first and writes the
# deterministic '## Pipeline' section into the body immediately afterwards, so
# the 'opened' run always saw an unsigned snapshot of a PR that was compliant
# seconds later. The workflow deliberately gives each opened/edited event its
# own immutable concurrency group, so no later event can replace that verdict:
# the PR was left with a permanently red required check it could never turn
# green. The step must therefore re-read the LIVE body before failing.
#
# These tests extract the step's real shell body out of the workflow YAML and
# run it against stub `gh`/`sleep` binaries, so they exercise the exact script
# GitHub Actions runs rather than a re-spelled copy of it.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
TMP_ROOT=$(fm_test_tmproot no-mistakes-required-workflow)
mkdir -p "$TMP_ROOT"
trap 'fm_test_cleanup; rm -rf "$TMP_ROOT"' EXIT

MARKER='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
SIGNED_BODY="## Summary
- something

## Pipeline

$MARKER"
UNSIGNED_BODY="## Summary
- something

## Test plan
- [x] ran the tests"

# --- extract the verify step's shell body from the workflow -----------------

STEP_SCRIPT="$TMP_ROOT/verify-step.sh"
awk '
  /^        run: \|$/ { collecting = 1; next }
  collecting {
    if ($0 == "") { print ""; next }
    if ($0 !~ /^          /) { collecting = 0; next }
    print substr($0, 11)
  }
' "$WORKFLOW" >"$STEP_SCRIPT"

[ -s "$STEP_SCRIPT" ] \
  || fail "could not extract the verify step's run: block from $WORKFLOW"
assert_grep "$MARKER" "$STEP_SCRIPT" \
  "extracted step body must contain the no-mistakes signature marker"

# run_step <event-body> <live-body>: run the extracted step and set STEP_OUT
# (combined output), STEP_CODE, and STEP_GH_CALLS. Must NOT be called from a
# command substitution, or the results would be set in a discarded subshell.
# `gh` and `sleep` are stubbed so the retry loop is exercised without any real
# network or wall-clock cost. An empty <live-body> makes the gh stub fail.
STEP_OUT=
STEP_CODE=0
STEP_GH_CALLS=0
STEP_GH_ARGS=
run_step() {
  local pr_body=$1 live_body=$2 run_dir fakebin
  run_dir=$(mktemp -d "$TMP_ROOT/run.XXXXXX")
  fakebin=$(fm_fakebin "$run_dir")
  printf '%s' "$live_body" >"$run_dir/live-body"

  cat >"$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf 'x\n' >>"$STUB_DIR/gh-calls"
printf '%s' "$*" >>"$STUB_DIR/gh-args"
printf '\n' >>"$STUB_DIR/gh-args"
[ -s "$STUB_DIR/live-body" ] || exit 1
cat "$STUB_DIR/live-body"
SH
  cat >"$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh" "$fakebin/sleep"

  STUB_DIR="$run_dir" \
  PATH="$fakebin:$PATH" \
  PR_BODY="$pr_body" \
  PR_AUTHOR=someone \
  PR_NUMBER=123 \
  PR_REPO=owner/repo \
  bash "$STEP_SCRIPT" >"$run_dir/out" 2>&1
  STEP_CODE=$?
  STEP_OUT=$(cat "$run_dir/out")
  if [ -f "$run_dir/gh-calls" ]; then
    STEP_GH_CALLS=$(wc -l <"$run_dir/gh-calls" | tr -d ' ')
    STEP_GH_ARGS=$(cat "$run_dir/gh-args")
  else
    STEP_GH_CALLS=0
    STEP_GH_ARGS=
  fi
}

# --- tests ------------------------------------------------------------------

test_signed_event_body_passes_without_api_call() {
  run_step "$SIGNED_BODY" ""
  expect_code 0 "$STEP_CODE" "signed event body must pass"
  assert_contains "$STEP_OUT" "Found no-mistakes signature in PR #123 body." \
    "signed event body must report the signature"
  [ "$STEP_GH_CALLS" -eq 0 ] \
    || fail "a signed event body must not need an API re-read (gh called $STEP_GH_CALLS times)"
  pass "signed event body passes straight through with no live re-read"
}

test_stale_event_body_passes_on_live_reread() {
  run_step "$UNSIGNED_BODY" "$SIGNED_BODY"
  expect_code 0 "$STEP_CODE" \
    "a stale unsigned snapshot must pass once the live body carries the signature"
  assert_contains "$STEP_OUT" "Found no-mistakes signature in the live PR #123 body" \
    "live re-read success must be reported"
  [ "$STEP_GH_CALLS" -ge 1 ] || fail "the live body was never re-read"
  assert_contains "$STEP_GH_ARGS" "repos/owner/repo/pulls/123" \
    "the re-read must query this PR's own API endpoint"
  pass "stale 'opened' snapshot passes once the live PR body is signed"
}

test_unsigned_live_body_still_fails_with_guidance() {
  run_step "$UNSIGNED_BODY" "$UNSIGNED_BODY"
  expect_code 1 "$STEP_CODE" "a genuinely unsigned PR must still fail"
  assert_contains "$STEP_OUT" "This PR was not raised through no-mistakes." \
    "failure must keep the contributor guidance"
  assert_contains "$STEP_OUT" "PR author: someone" \
    "failure must still name the PR author"
  [ "$STEP_GH_CALLS" -gt 1 ] \
    || fail "failing the check must retry the live re-read (gh called $STEP_GH_CALLS times)"
  pass "unsigned live body still fails, after retrying the live re-read"
}

test_api_failure_falls_back_to_failing_closed() {
  # Empty live-body file makes the gh stub exit non-zero: a token/API problem
  # must not crash the step under `set -eu`, it must fail the check cleanly.
  run_step "$UNSIGNED_BODY" ""
  expect_code 1 "$STEP_CODE" "an API failure must fail the check, not error out"
  assert_contains "$STEP_OUT" "This PR was not raised through no-mistakes." \
    "API failure must still print the contributor guidance"
  pass "live re-read failure fails the check closed with guidance"
}

test_workflow_grants_pull_request_read() {
  # The live re-read is only possible with this permission; without it the
  # workflow would silently regress to snapshot-only behavior in CI.
  assert_grep "pull-requests: read" "$WORKFLOW" \
    "workflow must grant pull-requests: read for the live body re-read"
  # shellcheck disable=SC2016  # literal YAML expression, must not expand here
  assert_grep 'GH_TOKEN: ${{ github.token }}' "$WORKFLOW" \
    "verify step must pass a token to gh"
  pass "workflow grants the permission and token the live re-read needs"
}

test_signed_event_body_passes_without_api_call
test_stale_event_body_passes_on_live_reread
test_unsigned_live_body_still_fails_with_guidance
test_api_failure_falls_back_to_failing_closed
test_workflow_grants_pull_request_read

echo "all no-mistakes-required-workflow tests passed"
