#!/usr/bin/env bash
# Behavior tests for fm-browser-mcp-pin.sh, the owner of the chrome-devtools-mcp
# build crewmate browser work is pinned to.
#
# Every case drives the real script through its command-line interface with an
# isolated home and pin root, so the assertions pin the resolution order and the
# exit-code contract bin/fm-spawn.sh depends on, not the script's source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PIN="$ROOT/bin/fm-browser-mcp-pin.sh"
TMP_ROOT=$(fm_test_tmproot fm-browser-mcp-pin)

# An isolated home plus an empty pin root. Prints "home|root".
make_pin_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/home/config" "$case_dir/home/state" "$case_dir/home/data" "$case_dir/root"
  printf '%s\n' "$case_dir/home|$case_dir/root"
}

read_pin_case() {
  IFS='|' read -r HOME_DIR ROOT_DIR <<EOF
$1
EOF
}

# Lay down a file shaped like an installed chrome-devtools-mcp entry point under
# the pin root, so resolution can find one without a real npm install.
install_fake_pin() {
  local root=$1 version=$2 entry
  entry="$root/$version/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js"
  mkdir -p "$(dirname "$entry")"
  printf '// fake chrome-devtools-mcp %s\n' "$version" > "$entry"
  printf '%s\n' "$entry"
}

# The suite lifts the pin globally (tests/lib.sh), so every case here states its
# own sources rather than inheriting that default.
run_pin() {
  local home=$1 root=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_BROWSER_MCP_ROOT="$root" FM_BROWSER_MCP_PIN="${CASE_ENV_PIN:-}" \
    CHROME_DEVTOOLS_AXI_MCP_PATH="${CASE_INHERITED_PIN:-}" \
    "$PIN" "$@"
}

test_version_is_reported() {
  local rec out
  rec=$(make_pin_case version)
  read_pin_case "$rec"
  out=$(run_pin "$HOME_DIR" "$ROOT_DIR" --version)
  expect_code 0 "$?" "--version should succeed"
  [ -n "$out" ] || fail "--version printed nothing"
  case "$out" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) fail "--version did not print a version: $out" ;;
  esac
  pass "the pinned chrome-devtools-mcp version is reported through --version"
}

test_no_pin_anywhere_is_an_actionable_refusal() {
  local rec out err status
  rec=$(make_pin_case absent)
  read_pin_case "$rec"
  err="$TMP_ROOT/absent.err"
  out=$(run_pin "$HOME_DIR" "$ROOT_DIR" path 2>"$err")
  status=$?
  expect_code 2 "$status" "an unresolvable pin should exit 2"
  [ -z "$out" ] || fail "an unresolvable pin printed a path: $out"
  assert_grep "--ensure" "$err" "the refusal did not name the command that installs the pin"
  pass "no pin anywhere refuses with an actionable reason and no path"
}

test_configured_off_lifts_the_pin_silently() {
  local rec out err status
  rec=$(make_pin_case off)
  read_pin_case "$rec"
  err="$TMP_ROOT/off.err"
  printf 'off\n' > "$HOME_DIR/config/browser-mcp-pin"
  out=$(run_pin "$HOME_DIR" "$ROOT_DIR" path 2>"$err")
  status=$?
  expect_code 3 "$status" "a lifted pin should exit 3"
  [ -z "$out" ] || fail "a lifted pin printed a path: $out"
  [ ! -s "$err" ] || fail "a lifted pin is a deliberate choice and must stay silent: $(cat "$err")"
  pass "config/browser-mcp-pin=off lifts the pin with its own exit code and no diagnostic"
}

test_installed_fleet_pin_resolves() {
  local rec out entry
  rec=$(make_pin_case installed)
  read_pin_case "$rec"
  entry=$(install_fake_pin "$ROOT_DIR" "$(run_pin "$HOME_DIR" "$ROOT_DIR" --version)")
  out=$(run_pin "$HOME_DIR" "$ROOT_DIR" path)
  expect_code 0 "$?" "an installed pin should resolve"
  [ "$out" = "$entry" ] || fail "resolved pin was not the installed entry point"$'\n'"expected: $entry"$'\n'"actual:   $out"
  pass "an installed fleet pin resolves to its entry point"
}

test_configured_path_wins_over_the_installed_pin() {
  local rec out configured
  rec=$(make_pin_case configured)
  read_pin_case "$rec"
  install_fake_pin "$ROOT_DIR" "$(run_pin "$HOME_DIR" "$ROOT_DIR" --version)" >/dev/null
  configured="$TMP_ROOT/configured/other-mcp.js"
  mkdir -p "$(dirname "$configured")"
  printf '// other build\n' > "$configured"
  printf '# a comment line the reader skips\n\n%s\n' "$configured" > "$HOME_DIR/config/browser-mcp-pin"
  out=$(run_pin "$HOME_DIR" "$ROOT_DIR" path)
  expect_code 0 "$?" "a configured pin path should resolve"
  [ "$out" = "$configured" ] || fail "the configured path did not win over the installed pin: $out"
  pass "a configured pin path wins over the installed one, past comments and blank lines"
}

test_configured_missing_path_refuses_rather_than_falling_back() {
  local rec out err status
  rec=$(make_pin_case configured_missing)
  read_pin_case "$rec"
  err="$TMP_ROOT/configured_missing.err"
  install_fake_pin "$ROOT_DIR" "$(run_pin "$HOME_DIR" "$ROOT_DIR" --version)" >/dev/null
  printf '%s\n' "$TMP_ROOT/configured_missing/nothing-here.js" > "$HOME_DIR/config/browser-mcp-pin"
  out=$(run_pin "$HOME_DIR" "$ROOT_DIR" path 2>"$err")
  status=$?
  expect_code 2 "$status" "a configured pin naming a missing file should exit 2"
  [ -z "$out" ] || fail "a missing configured pin still printed a path: $out"
  assert_grep "nothing-here.js" "$err" "the refusal did not name the missing configured path"
  pass "a configured pin naming nothing refuses instead of silently using the installed one"
}

test_inherited_env_wins_over_configuration() {
  local rec out inherited configured
  rec=$(make_pin_case inherited)
  read_pin_case "$rec"
  inherited="$TMP_ROOT/inherited/inherited-mcp.js"
  configured="$TMP_ROOT/inherited/configured-mcp.js"
  mkdir -p "$TMP_ROOT/inherited"
  printf '// inherited\n' > "$inherited"
  printf '// configured\n' > "$configured"
  printf '%s\n' "$configured" > "$HOME_DIR/config/browser-mcp-pin"
  out=$(CASE_INHERITED_PIN="$inherited" run_pin "$HOME_DIR" "$ROOT_DIR" path)
  expect_code 0 "$?" "an inherited pin should resolve"
  [ "$out" = "$inherited" ] || fail "the inherited pin did not win over configuration: $out"
  pass "an inherited CHROME_DEVTOOLS_AXI_MCP_PATH wins over the configured pin"
}

test_env_override_lifts_the_pin_without_touching_config() {
  local rec out status
  rec=$(make_pin_case env_off)
  read_pin_case "$rec"
  install_fake_pin "$ROOT_DIR" "$(run_pin "$HOME_DIR" "$ROOT_DIR" --version)" >/dev/null
  out=$(CASE_ENV_PIN=off run_pin "$HOME_DIR" "$ROOT_DIR" path 2>/dev/null)
  status=$?
  expect_code 3 "$status" "FM_BROWSER_MCP_PIN=off should lift the pin"
  [ -z "$out" ] || fail "a lifted pin printed a path: $out"
  [ ! -f "$HOME_DIR/config/browser-mcp-pin" ] || fail "the env override wrote configuration"
  pass "FM_BROWSER_MCP_PIN=off lifts the pin for one process tree without writing config"
}

test_ensure_never_installs_over_an_explicit_pin() {
  local rec out err status
  rec=$(make_pin_case ensure_explicit)
  read_pin_case "$rec"
  err="$TMP_ROOT/ensure_explicit.err"
  printf '%s\n' "$TMP_ROOT/ensure_explicit/nothing-here.js" > "$HOME_DIR/config/browser-mcp-pin"
  out=$(run_pin "$HOME_DIR" "$ROOT_DIR" --ensure 2>"$err")
  status=$?
  expect_code 2 "$status" "--ensure should refuse when an explicit pin names nothing"
  [ -z "$out" ] || fail "--ensure printed a path it did not install: $out"
  assert_grep "nothing-here.js" "$err" "the refusal did not name the explicit pin"
  [ -z "$(ls -A "$ROOT_DIR")" ] || fail "--ensure installed into the fleet root despite an explicit pin"
  pass "--ensure reports an explicit pin that names nothing instead of installing around it"
}

test_ensure_is_a_no_op_once_the_pin_is_present() {
  local rec out entry before
  rec=$(make_pin_case ensure_present)
  read_pin_case "$rec"
  entry=$(install_fake_pin "$ROOT_DIR" "$(run_pin "$HOME_DIR" "$ROOT_DIR" --version)")
  before=$(cat "$entry")
  out=$(run_pin "$HOME_DIR" "$ROOT_DIR" --ensure)
  expect_code 0 "$?" "--ensure should succeed when the pin is already installed"
  [ "$out" = "$entry" ] || fail "--ensure did not print the installed entry point: $out"
  [ "$(cat "$entry")" = "$before" ] || fail "--ensure reinstalled over a present pin"
  pass "--ensure prints the present pin without reinstalling it"
}

test_unknown_argument_is_refused() {
  local status
  run_pin "$(make_pin_case unknown | cut -d'|' -f1)" "$TMP_ROOT/unknown/root" --nonsense >/dev/null 2>&1
  status=$?
  expect_code 64 "$status" "an unknown argument should be a usage error"
  pass "an unknown argument is refused as a usage error"
}

test_version_is_reported
test_no_pin_anywhere_is_an_actionable_refusal
test_configured_off_lifts_the_pin_silently
test_installed_fleet_pin_resolves
test_configured_path_wins_over_the_installed_pin
test_configured_missing_path_refuses_rather_than_falling_back
test_inherited_env_wins_over_configuration
test_env_override_lifts_the_pin_without_touching_config
test_ensure_never_installs_over_an_explicit_pin
test_ensure_is_a_no_op_once_the_pin_is_present
test_unknown_argument_is_refused
