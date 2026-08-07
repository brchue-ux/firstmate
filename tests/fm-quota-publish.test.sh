#!/usr/bin/env bash
# Tests for bin/fm-quota-publish.sh: reads one provider's session (5-hour)
# and weekly (7-day) quota windows from `quota-axi --json` and publishes them
# as two herdr metadata tokens onto this home's own workspace.
#
# Fake-CLI unit tests (mirrors tests/fm-quality-event.test.sh's fakebin/
# command-log convention): `quota-axi` and `herdr` stubs that log every
# invocation and exit with a configurable code, so assertions are on what got
# called, never on the script's implementation bytes.
#
# Matrix:
#   (a) a herdr-backed home with both windows publishes exactly one
#       report-metadata call carrying quota_5h and quota_7d tokens, each
#       "<percentUsed>@<resetsAt>"
#   (b) a window with no resetsAt publishes "<percentUsed>" with no "@"
#   (c) an unknown provider: usage/data error, exit 1, no herdr call
#   (d) a provider missing its session window: exit 1, no herdr call
#   (e) a provider missing its weekly window: exit 1, no herdr call
#   (f) wrong argument count: usage error, exit 2
#   (g) an empty provider argument: usage error, exit 2
#   (h) no herdr workspace resolvable for this home: silent no-op, exit 0
#   (i) the herdr CLI itself failing never fails the script
#   (j) a failing quota-axi call is a caller-visible error, exit 1
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by fm-quota-publish.sh)"; exit 0; }

SUBJECT="$ROOT/bin/fm-quota-publish.sh"
TMP_ROOT=$(fm_test_tmproot fm-quota-publish-tests)

# Build a fresh sandbox: a fresh FM_HOME plus a fakebin with quota-axi and
# herdr stubs. quota-axi prints the fixture JSON at $case_dir/quota.json
# ("--json" is ignored, matching the real CLI's default-to-JSON-file
# convenience for this stub); herdr logs every invocation
# ("HERDR_SESSION=<val> ARGS=<args>", one line per call) to
# $case_dir/herdr.log and exits 0 unless $case_dir/herdr-exit overrides it.
# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/home/state" "$fakebin"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf 'HERDR_SESSION=%s ARGS=%s\n' "${HERDR_SESSION:-}" "$*" >> "${FM_TEST_HERDR_LOG:?}"
exit "$(cat "${FM_TEST_HERDR_EXIT_FILE:?}" 2>/dev/null || echo 0)"
SH
  chmod +x "$fakebin/herdr"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
exit_file="${FM_TEST_QUOTA_AXI_EXIT_FILE:?}"
code=$(cat "$exit_file" 2>/dev/null || echo 0)
if [ "$code" -eq 0 ]; then
  cat "${FM_TEST_QUOTA_JSON:?}"
fi
exit "$code"
SH
  chmod +x "$fakebin/quota-axi"
  : > "$case_dir/herdr.log"
  printf '0\n' > "$case_dir/herdr-exit"
  printf '0\n' > "$case_dir/quota-axi-exit"
  printf '%s\n' "$case_dir"
}

write_quota_json() {  # <case_dir> <json>
  printf '%s' "$2" > "$1/quota.json"
}

quota_json_two_windows() {  # <provider> <five_hour_pct> <five_hour_resets> <seven_day_pct> <seven_day_resets>
  jq -nc \
    --arg provider "$1" --argjson p5 "$2" --arg r5 "$3" --argjson p7 "$4" --arg r7 "$5" \
    '{
      generatedAt: "2026-08-07T14:29:28.736Z",
      schemaVersion: 2,
      providers: [{
        provider: $provider, label: $provider, source: "test", plan: "test",
        windows: [
          ({id: "five_hour", label: "session", kind: "session", percentUsed: $p5, percentRemaining: (100 - $p5)}
            + (if $r5 == "" then {} else {resetsAt: $r5} end)),
          ({id: "seven_day", label: "week", kind: "weekly", percentUsed: $p7, percentRemaining: (100 - $p7)}
            + (if $r7 == "" then {} else {resetsAt: $r7} end))
        ]
      }]
    }'
}

write_herdr_workspace() {  # <case_dir> <workspace_id>
  local case_dir=$1 wsid=$2
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
printf 'HERDR_SESSION=%s ARGS=%s\n' "\${HERDR_SESSION:-}" "\$*" >> "\${FM_TEST_HERDR_LOG:?}"
if [ "\$1" = workspace ] && [ "\$2" = list ]; then
  printf '{"result":{"workspaces":[{"workspace_id":"$wsid","label":"firstmate"}]}}\n'
fi
exit "\$(cat "\${FM_TEST_HERDR_EXIT_FILE:?}" 2>/dev/null || echo 0)"
SH
  chmod +x "$case_dir/fakebin/herdr"
}

run_publish() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/home/state" \
  FM_TEST_HERDR_LOG="$case_dir/herdr.log" \
  FM_TEST_HERDR_EXIT_FILE="$case_dir/herdr-exit" \
  FM_TEST_QUOTA_JSON="$case_dir/quota.json" \
  FM_TEST_QUOTA_AXI_EXIT_FILE="$case_dir/quota-axi-exit" \
  PATH="$case_dir/fakebin:$PATH" \
    "$SUBJECT" "$@"
}

test_herdr_home_publishes_two_tokens_with_resets() {
  local case_dir rc calls
  case_dir=$(make_case two-tokens)
  write_herdr_workspace "$case_dir" ws1
  write_quota_json "$case_dir" "$(quota_json_two_windows claude 9 '2026-08-07T17:30:00+00:00' 9 '2026-08-10T05:00:00+00:00')"

  set +e
  run_publish "$case_dir" claude > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "two-tokens: publish should succeed"
  calls=$(grep -c 'report-metadata' "$case_dir/herdr.log" || true)
  [ "$calls" = 1 ] || fail "two-tokens: expected exactly one report-metadata call, got $calls"
  assert_grep 'quota_5h=9@2026-08-07T17:30:00+00:00' "$case_dir/herdr.log" "two-tokens: quota_5h token missing or wrong"
  assert_grep 'quota_7d=9@2026-08-10T05:00:00+00:00' "$case_dir/herdr.log" "two-tokens: quota_7d token missing or wrong"
  assert_grep '--source firstmate' "$case_dir/herdr.log" "two-tokens: --source firstmate missing"
  pass "fm-quota-publish publishes quota_5h and quota_7d tokens with percentage and resetsAt"
}

test_missing_resets_at_omits_the_at_sign() {
  local case_dir
  case_dir=$(make_case no-resets)
  write_herdr_workspace "$case_dir" ws1
  write_quota_json "$case_dir" "$(quota_json_two_windows claude 20 '' 20 '')"

  run_publish "$case_dir" claude > "$case_dir/stdout" 2> "$case_dir/stderr"

  assert_grep 'quota_5h=20 ' "$case_dir/herdr.log" "no-resets: quota_5h should publish bare percentage"
  assert_no_grep 'quota_5h=20@' "$case_dir/herdr.log" "no-resets: quota_5h should not carry an empty @resetsAt"
  pass "fm-quota-publish publishes a bare percentage when resetsAt is absent"
}

test_unknown_provider_is_a_data_error() {
  local case_dir rc
  case_dir=$(make_case unknown-provider)
  write_quota_json "$case_dir" "$(quota_json_two_windows claude 9 '2026-08-07T17:30:00+00:00' 9 '2026-08-10T05:00:00+00:00')"

  set +e
  run_publish "$case_dir" codex > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unknown-provider: should fail"
  assert_grep "no provider 'codex'" "$case_dir/stderr" "unknown-provider: error did not name the provider"
  [ ! -s "$case_dir/herdr.log" ] || fail "unknown-provider: herdr should never be called"
  pass "fm-quota-publish fails with a clear error for a provider absent from quota-axi output"
}

test_missing_session_window_is_a_data_error() {
  local case_dir rc json
  case_dir=$(make_case missing-session)
  json=$(jq -nc '{
    providers: [{ provider: "claude", windows: [
      {id: "seven_day", label: "week", kind: "weekly", percentUsed: 9, resetsAt: "2026-08-10T05:00:00+00:00"}
    ]}]
  }')
  write_quota_json "$case_dir" "$json"

  set +e
  run_publish "$case_dir" claude > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-session: should fail"
  assert_grep 'session (5-hour)' "$case_dir/stderr" "missing-session: error did not name the missing window"
  [ ! -s "$case_dir/herdr.log" ] || fail "missing-session: herdr should never be called"
  pass "fm-quota-publish fails with a clear error when the session window is absent"
}

test_missing_weekly_window_is_a_data_error() {
  local case_dir rc json
  case_dir=$(make_case missing-weekly)
  json=$(jq -nc '{
    providers: [{ provider: "claude", windows: [
      {id: "five_hour", label: "session", kind: "session", percentUsed: 9, resetsAt: "2026-08-07T17:30:00+00:00"}
    ]}]
  }')
  write_quota_json "$case_dir" "$json"

  set +e
  run_publish "$case_dir" claude > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-weekly: should fail"
  assert_grep 'weekly (7-day)' "$case_dir/stderr" "missing-weekly: error did not name the missing window"
  [ ! -s "$case_dir/herdr.log" ] || fail "missing-weekly: herdr should never be called"
  pass "fm-quota-publish fails with a clear error when the weekly window is absent"
}

test_wrong_arg_count_is_a_usage_error() {
  local case_dir rc
  case_dir=$(make_case wrong-arg-count)

  set +e
  run_publish "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "wrong-arg-count: a missing provider argument should be refused"
  assert_grep 'usage:' "$case_dir/stderr" "wrong-arg-count: refusal did not explain usage"
  pass "fm-quota-publish refuses a call with the wrong argument count"
}

test_empty_provider_is_a_usage_error() {
  local case_dir rc
  case_dir=$(make_case empty-provider)

  set +e
  run_publish "$case_dir" '' > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "empty-provider: an empty provider should be refused"
  assert_grep 'usage:' "$case_dir/stderr" "empty-provider: refusal did not explain usage"
  pass "fm-quota-publish refuses an empty provider argument"
}

test_no_matching_workspace_publishes_nothing() {
  local case_dir rc
  case_dir=$(make_case no-workspace)
  write_quota_json "$case_dir" "$(quota_json_two_windows claude 9 '2026-08-07T17:30:00+00:00' 9 '2026-08-10T05:00:00+00:00')"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
printf 'HERDR_SESSION=%s ARGS=%s\n' "\${HERDR_SESSION:-}" "\$*" >> "\${FM_TEST_HERDR_LOG:?}"
if [ "\$1" = workspace ] && [ "\$2" = list ]; then
  printf '{"result":{"workspaces":[]}}\n'
fi
exit "\$(cat "\${FM_TEST_HERDR_EXIT_FILE:?}" 2>/dev/null || echo 0)"
SH
  chmod +x "$case_dir/fakebin/herdr"

  set +e
  run_publish "$case_dir" claude > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-workspace: should still succeed"
  assert_no_grep 'report-metadata' "$case_dir/herdr.log" "no-workspace: report-metadata should never be called"
  pass "fm-quota-publish is a silent no-op toward herdr when no workspace matches this home"
}

test_herdr_cli_failure_never_fails_the_script() {
  local case_dir rc
  case_dir=$(make_case cli-failure)
  write_quota_json "$case_dir" "$(quota_json_two_windows claude 9 '2026-08-07T17:30:00+00:00' 9 '2026-08-10T05:00:00+00:00')"
  # workspace list must still succeed so target resolution finds a workspace;
  # only the report-metadata call itself fails, so this exercises the
  # publish-call failure path, not target resolution failing too.
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
printf 'HERDR_SESSION=%s ARGS=%s\n' "\${HERDR_SESSION:-}" "\$*" >> "\${FM_TEST_HERDR_LOG:?}"
if [ "\$1" = workspace ] && [ "\$2" = list ]; then
  printf '{"result":{"workspaces":[{"workspace_id":"ws1","label":"firstmate"}]}}\n'
  exit 0
fi
exit 1
SH
  chmod +x "$case_dir/fakebin/herdr"

  set +e
  run_publish "$case_dir" claude > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "cli-failure: a failing herdr CLI call should never fail the script"
  assert_grep 'report-metadata' "$case_dir/herdr.log" "cli-failure: report-metadata was not attempted"
  pass "fm-quota-publish never fails when the underlying herdr CLI call fails"
}

test_quota_axi_failure_is_a_caller_visible_error() {
  local case_dir rc
  case_dir=$(make_case quota-axi-failure)
  write_quota_json "$case_dir" "$(quota_json_two_windows claude 9 '2026-08-07T17:30:00+00:00' 9 '2026-08-10T05:00:00+00:00')"
  printf '1\n' > "$case_dir/quota-axi-exit"

  set +e
  run_publish "$case_dir" claude > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "quota-axi-failure: should fail"
  assert_grep 'quota-axi --json failed' "$case_dir/stderr" "quota-axi-failure: error did not explain the cause"
  pass "fm-quota-publish fails visibly when quota-axi itself fails"
}

test_herdr_home_publishes_two_tokens_with_resets
test_missing_resets_at_omits_the_at_sign
test_unknown_provider_is_a_data_error
test_missing_session_window_is_a_data_error
test_missing_weekly_window_is_a_data_error
test_wrong_arg_count_is_a_usage_error
test_empty_provider_is_a_usage_error
test_no_matching_workspace_publishes_nothing
test_herdr_cli_failure_never_fails_the_script
test_quota_axi_failure_is_a_caller_visible_error
