#!/usr/bin/env bash
# Tests for bin/fm-herdr-owner-publish.sh: the publisher that tags a
# STANDALONE-CLONE secondmate's herdr workspace with owner=<this home's own
# workspace label>, so herdr can nest it under the primary, and that stays
# completely out of the way of a LINKED-WORKTREE secondmate, whose parentage
# herdr already derives from the shared repository.
#
# Fake-herdr-CLI unit tests (mirrors tests/fm-herdr-outcome-publish.test.sh's
# fakebin/command-log convention): a `herdr` stub that logs every invocation
# and exits with a configurable code, so assertions are on what got called,
# never on the script's implementation bytes. The git checkouts under test are
# REAL repositories and REAL linked worktrees built by the test, so the
# standalone-vs-linked classification is exercised against git itself.
#
# Matrix:
#   (a) standalone-clone secondmate -> exactly one report-metadata call
#       carrying owner=<label>, and no --ttl-ms (the token must never expire)
#   (b) linked-worktree secondmate -> no herdr call at all, exit 0
#   (c) a secondmate home that is not a git repo at all -> tagged, since it
#       gives herdr no shared-repository signal either
#   (d) the owner value follows this home's own workspace label, so a
#       secondmate-shaped publishing home tags with its own label rather than
#       a hard-coded "firstmate"
#   (e) kind=ship (an ordinary crewmate) -> no herdr call, exit 0
#   (f) non-herdr secondmate (no backend= line) -> no herdr call, exit 0
#   (g) secondmate meta missing herdr_workspace_id -> no call, exit 0
#   (h) secondmate meta missing home= -> no call, exit 0
#   (i) missing task meta -> no call, exit 0
#   (j) wrong argument count, and an unsafe task id -> usage error, exit 2,
#       no herdr call
#   (k) the herdr CLI itself failing never fails the publisher (exit 0)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found (required to build the checkouts under test)"; exit 0; }

PUBLISH="$ROOT/bin/fm-herdr-owner-publish.sh"
TMP_ROOT=$(fm_test_tmproot fm-herdr-owner-publish-tests)

git_quiet() { git -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "$@"; }

# A real repository with one commit, so `git worktree add` can branch from it.
make_standalone_repo() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git_quiet -C "$dir" init -q
  printf '# scratch\n' > "$dir/README.md"
  git_quiet -C "$dir" add README.md
  git_quiet -C "$dir" commit -qm initial
}

# A real LINKED worktree of <repo>, the shape herdr already groups for free.
make_linked_worktree() {  # <repo> <dir> <branch>
  git_quiet -C "$1" worktree add -q -b "$3" "$2" >/dev/null 2>&1
}

# Build a fresh sandbox: a state dir, a publishing home, and a fakebin with a
# herdr stub that logs every invocation ("HERDR_SESSION=<val> ARGS=<args>", one
# line per call) to $case_dir/herdr.log and exits 0 unless $case_dir/herdr-exit
# overrides it. Echoes the case dir.
make_case() {  # <name>
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/home" "$fakebin"
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

write_secondmate_meta() {  # <case-dir> <home-path> [extra-key=value...]
  local case_dir=$1 home_path=$2
  shift 2
  fm_write_meta "$case_dir/state/sm-x1.meta" \
    "window=fmtest:w7:p3" \
    "worktree=$home_path" \
    "project=$home_path" \
    "kind=secondmate" \
    "mode=secondmate" \
    "backend=herdr" \
    "herdr_session=fmtest" \
    "herdr_workspace_id=w7" \
    "herdr_tab_id=w7:t3" \
    "herdr_pane_id=w7:p3" \
    "home=$home_path" \
    "$@"
}

run_publish() {  # <case-dir> <args...>
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_HERDR_LOG="$case_dir/herdr.log" \
  FM_TEST_HERDR_EXIT_FILE="$case_dir/herdr-exit" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PUBLISH" "$@"
}

# Every no-op case asserts the same thing: exit 0 and a completely empty herdr
# command log, because "did not disturb herdr" is the actual requirement.
expect_silent_noop() {  # <case-dir> <label> <message>
  local case_dir=$1 label=$2 message=$3 rc
  set +e
  run_publish "$case_dir" sm-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "$label: publish should exit 0"
  [ ! -s "$case_dir/herdr.log" ] || fail "$message"$'\n'"--- herdr calls ---"$'\n'"$(cat "$case_dir/herdr.log")"
}

test_standalone_clone_is_tagged_without_a_ttl() {
  local case_dir rc calls
  case_dir=$(make_case standalone-clone)
  make_standalone_repo "$case_dir/sm-home"
  write_secondmate_meta "$case_dir" "$case_dir/sm-home"

  set +e
  run_publish "$case_dir" sm-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "standalone-clone: publish should succeed"
  assert_grep 'HERDR_SESSION=fmtest ARGS=workspace report-metadata w7 --source firstmate --token owner=firstmate --session fmtest' \
    "$case_dir/herdr.log" "standalone-clone: report-metadata was not called as expected"
  calls=$(grep -c 'report-metadata' "$case_dir/herdr.log" || true)
  [ "$calls" = 1 ] || fail "standalone-clone: expected exactly one report-metadata call, got $calls"
  assert_no_grep '--ttl-ms' "$case_dir/herdr.log" \
    "standalone-clone: the owner token must never expire, so no --ttl-ms may be passed"
  pass "fm-herdr-owner-publish tags a standalone-clone secondmate with a never-expiring owner token"
}

test_linked_worktree_is_left_completely_alone() {
  local case_dir
  case_dir=$(make_case linked-worktree)
  make_standalone_repo "$case_dir/upstream"
  make_linked_worktree "$case_dir/upstream" "$case_dir/sm-home" sm-branch
  [ -f "$case_dir/sm-home/.git" ] || fail "linked-worktree: fixture is not a linked worktree"
  write_secondmate_meta "$case_dir" "$case_dir/sm-home"

  expect_silent_noop "$case_dir" linked-worktree \
    "linked-worktree: a linked-worktree secondmate must not be touched at all - herdr already derives its parentage"
  pass "fm-herdr-owner-publish makes no herdr call whatsoever for a linked-worktree secondmate"
}

test_non_repo_home_is_tagged() {
  local case_dir rc
  case_dir=$(make_case non-repo-home)
  mkdir -p "$case_dir/sm-home"
  write_secondmate_meta "$case_dir" "$case_dir/sm-home"

  set +e
  run_publish "$case_dir" sm-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "non-repo-home: publish should succeed"
  assert_grep '--token owner=firstmate' "$case_dir/herdr.log" \
    "non-repo-home: a home that is not a repository has no shared-repository signal either, so it must still be tagged"
  pass "fm-herdr-owner-publish tags a secondmate home that is not a git repository at all"
}

test_owner_value_follows_this_homes_own_label() {
  local case_dir rc
  case_dir=$(make_case own-label)
  make_standalone_repo "$case_dir/sm-home"
  write_secondmate_meta "$case_dir" "$case_dir/sm-home"
  # The publishing home is itself secondmate-shaped, so its own workspace label
  # is 2ndmate-<id>. The owner token must follow that label, not a hard-coded
  # "firstmate": whichever home spawns is the parent the space belongs under.
  printf 'parentmate\n' > "$case_dir/home/.fm-secondmate-home"

  set +e
  run_publish "$case_dir" sm-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "own-label: publish should succeed"
  assert_grep '--token owner=2ndmate-parentmate' "$case_dir/herdr.log" \
    "own-label: the owner token must carry the publishing home's own workspace label"
  assert_no_grep '--token owner=firstmate' "$case_dir/herdr.log" \
    "own-label: the owner token must not fall back to a hard-coded 'firstmate'"
  pass "fm-herdr-owner-publish reports the publishing home's own workspace label as the owner"
}

test_ordinary_crewmate_is_never_tagged() {
  local case_dir
  case_dir=$(make_case ordinary-crewmate)
  make_standalone_repo "$case_dir/sm-home"
  write_secondmate_meta "$case_dir" "$case_dir/sm-home"
  fm_write_meta "$case_dir/state/sm-x1.meta" \
    "window=fmtest:w7:p3" \
    "worktree=$case_dir/sm-home" \
    "project=$case_dir/sm-home" \
    "kind=ship" \
    "mode=no-mistakes" \
    "backend=herdr" \
    "herdr_session=fmtest" \
    "herdr_workspace_id=w7" \
    "herdr_tab_id=w7:t3" \
    "herdr_pane_id=w7:p3"

  expect_silent_noop "$case_dir" ordinary-crewmate \
    "ordinary-crewmate: only a secondmate task owns a home workspace; a crewmate must never be tagged"
  pass "fm-herdr-owner-publish is a silent no-op for an ordinary crewmate task"
}

test_non_herdr_secondmate_is_a_noop() {
  local case_dir
  case_dir=$(make_case non-herdr)
  make_standalone_repo "$case_dir/sm-home"
  fm_write_meta "$case_dir/state/sm-x1.meta" \
    "window=fm-sm-x1" \
    "worktree=$case_dir/sm-home" \
    "project=$case_dir/sm-home" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$case_dir/sm-home"

  expect_silent_noop "$case_dir" non-herdr \
    "non-herdr: a task with no recorded herdr backend must never reach the herdr CLI"
  pass "fm-herdr-owner-publish is a silent no-op for a non-herdr secondmate"
}

test_missing_workspace_field_is_a_noop() {
  local case_dir
  case_dir=$(make_case no-workspace)
  make_standalone_repo "$case_dir/sm-home"
  fm_write_meta "$case_dir/state/sm-x1.meta" \
    "window=fmtest:w7:p3" \
    "worktree=$case_dir/sm-home" \
    "project=$case_dir/sm-home" \
    "kind=secondmate" \
    "mode=secondmate" \
    "backend=herdr" \
    "herdr_session=fmtest" \
    "home=$case_dir/sm-home"

  expect_silent_noop "$case_dir" no-workspace \
    "no-workspace: with no recorded workspace there is nothing to address, so no call may be made"
  pass "fm-herdr-owner-publish is a silent no-op when the recorded herdr workspace is absent"
}

test_missing_home_field_is_a_noop() {
  local case_dir
  case_dir=$(make_case no-home-field)
  make_standalone_repo "$case_dir/sm-home"
  fm_write_meta "$case_dir/state/sm-x1.meta" \
    "window=fmtest:w7:p3" \
    "worktree=$case_dir/sm-home" \
    "project=$case_dir/sm-home" \
    "kind=secondmate" \
    "mode=secondmate" \
    "backend=herdr" \
    "herdr_session=fmtest" \
    "herdr_workspace_id=w7"

  expect_silent_noop "$case_dir" no-home-field \
    "no-home-field: without the secondmate's own home there is no checkout to classify, so nothing may be published"
  pass "fm-herdr-owner-publish is a silent no-op when the secondmate's home is not recorded"
}

test_missing_meta_is_a_noop() {
  local case_dir
  case_dir=$(make_case no-meta)

  expect_silent_noop "$case_dir" no-meta \
    "no-meta: a task with no durable record must never reach the herdr CLI"
  pass "fm-herdr-owner-publish is a silent no-op when the task has no recorded metadata"
}

test_malformed_calls_are_usage_errors() {
  local case_dir rc
  case_dir=$(make_case malformed)
  make_standalone_repo "$case_dir/sm-home"
  write_secondmate_meta "$case_dir" "$case_dir/sm-home"

  set +e
  run_publish "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "malformed: a call with no task id should be a usage error"

  set +e
  run_publish "$case_dir" sm-x1 extra > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "malformed: a call with too many arguments should be a usage error"

  set +e
  run_publish "$case_dir" ../escape > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "malformed: a path-unsafe task id should be a usage error"

  [ ! -s "$case_dir/herdr.log" ] || fail "malformed: a usage error must never reach the herdr CLI"
  pass "fm-herdr-owner-publish refuses a malformed call without touching herdr"
}

test_cli_failure_never_fails_the_publisher() {
  local case_dir rc
  case_dir=$(make_case cli-failure)
  make_standalone_repo "$case_dir/sm-home"
  write_secondmate_meta "$case_dir" "$case_dir/sm-home"
  printf '3\n' > "$case_dir/herdr-exit"

  set +e
  run_publish "$case_dir" sm-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "cli-failure: a failing herdr CLI must never fail the publisher"
  assert_grep 'report-metadata' "$case_dir/herdr.log" "cli-failure: report-metadata was not attempted"
  pass "fm-herdr-owner-publish never fails when the underlying herdr CLI call fails"
}

test_standalone_clone_is_tagged_without_a_ttl
test_linked_worktree_is_left_completely_alone
test_non_repo_home_is_tagged
test_owner_value_follows_this_homes_own_label
test_ordinary_crewmate_is_never_tagged
test_non_herdr_secondmate_is_a_noop
test_missing_workspace_field_is_a_noop
test_missing_home_field_is_a_noop
test_missing_meta_is_a_noop
test_malformed_calls_are_usage_errors
test_cli_failure_never_fails_the_publisher
