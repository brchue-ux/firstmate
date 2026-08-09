#!/usr/bin/env bash
# Behavior tests for fm-tmp-sweep.sh, the session-start reclamation of scratch
# directories orphaned in the shared temp root when a cleanup trap never ran.
#
# The sweep deletes things, so the cases that matter most are the ones that
# prove it does NOT: a scratch dir still being written, one a live process holds
# open, one that is not ours, one that is really an operational home, and every
# name outside the fm-<slug>.XXXXXX convention. Each case builds its own fake
# temp root so nothing here depends on, or touches, the host's real /tmp.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tmp-sweep)
SWEEP="$ROOT/bin/fm-tmp-sweep.sh"

HELD_PIDS=()

cleanup_all() {
  local pid
  for pid in "${HELD_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  fm_test_cleanup
}
trap cleanup_all EXIT

# age_out <path>...: stamp each path far enough in the past to clear any age
# window this suite uses. Deepest paths first, because writing or stamping a
# child restamps its parent.
age_out() {
  touch -t 202601010000 "$@"
}

# make_stale_dir <root> <name>: a scratch dir with a nested file, all aged out.
make_stale_dir() {
  local root=$1 name=$2 dir="$1/$2"
  mkdir -p "$dir/nested"
  printf 'fixture\n' > "$dir/nested/payload"
  age_out "$dir/nested/payload" "$dir/nested" "$dir"
  printf '%s\n' "$dir"
}

# make_fresh_dir <root> <name>: same shape, left at the current time.
make_fresh_dir() {
  local root=$1 name=$2 dir="$1/$2"
  mkdir -p "$dir/nested"
  printf 'fixture\n' > "$dir/nested/payload"
  printf '%s\n' "$dir"
}

new_root() {
  local root="$TMP_ROOT/$1"
  mkdir -p "$root"
  printf '%s\n' "$root"
}

# run_sweep <root> [extra args...]: run the sweep against a fixture root with a
# neutral working directory, so the caller's cwd can never be the thing that
# keeps a candidate alive.
run_sweep() {
  local root=$1
  shift
  (cd "$TMP_ROOT" && FM_TMP_SWEEP_ROOT="$root" FM_HOME='' "$SWEEP" "$@")
}

# hold_open <path> <marker>: hold a read fd on <path> from a live process until
# the suite exits, and return once the process has really opened it. <marker>
# must sit outside the swept root: writing it inside would restamp the candidate
# and let the age gate, not the open-handle check, be what saved it.
hold_open() {
  local path=$1 marker=$2 pid tries=0
  bash -c 'exec 9< "$1"; : > "$2"; sleep 120' _ "$path" "$marker" &
  pid=$!
  HELD_PIDS+=("$pid")
  while [ ! -e "$marker" ] && [ "$tries" -lt 200 ]; do
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -e "$marker" ] || fail "fixture: could not confirm the holder process opened $path"
  rm -f "$marker"
  printf '%s\n' "$pid"
}

test_removes_stale_scratch_dir() {
  local root dir out
  root=$(new_root removes-stale)
  dir=$(make_stale_dir "$root" fm-teardown-tests.aB3xY9)

  out=$(run_sweep "$root")
  assert_absent "$dir" "a stale orphaned scratch dir must be removed"
  assert_contains "$out" "fm-teardown-tests.aB3xY9: removed" \
    "removal must be reported as a notable outcome"
  pass "sweep removes a stale orphaned scratch dir and reports it"
}

test_leaves_fresh_scratch_dir() {
  local root dir out
  root=$(new_root leaves-fresh)
  dir=$(make_fresh_dir "$root" fm-secondmate-safety.Zz1234)

  out=$(run_sweep "$root")
  assert_present "$dir" "a scratch dir inside the age window must be left alone"
  [ -z "$out" ] || fail "an empty sweep must stay silent, got: $out"
  pass "sweep leaves a fresh scratch dir alone and stays silent"
}

test_leaves_dir_with_recent_deep_write() {
  local root dir out
  root=$(new_root leaves-deep-write)
  dir=$(make_stale_dir "$root" fm-longrun-tests.Cc3456)
  # A long test writes deep in the tree it was handed without ever restamping
  # the root, so a top-level mtime check alone would delete live scratch.
  printf 'still running\n' > "$dir/nested/payload"
  age_out "$dir"

  out=$(run_sweep "$root")
  assert_present "$dir" "a recent write anywhere in the tree must protect the whole dir"
  [ -z "$out" ] || fail "a protected dir must not be reported, got: $out"
  pass "sweep leaves a dir whose deep contents were just modified"
}

test_leaves_dir_held_open_by_live_process() {
  local root dir out checker
  for checker in lsof proc; do
    case "$checker" in
      lsof) command -v lsof >/dev/null 2>&1 || continue ;;
      proc) [ -r /proc/self/fd ] || continue ;;
    esac
    root=$(new_root "leaves-held-open-$checker")
    dir=$(make_stale_dir "$root" fm-held-tests.Dd7890)
    hold_open "$dir/nested/payload" "$TMP_ROOT/held-open-$checker.marker" >/dev/null

    # Control: with the holder gone the identical fixture is removed, so this
    # case can only pass because of the open-handle check.
    out=$(FM_TMP_SWEEP_CHECKER="$checker" run_sweep "$root")
    assert_present "$dir" "an aged-out dir held open by a live process must be left alone ($checker)"
    [ -z "$out" ] || fail "a held-open dir must not be reported ($checker), got: $out"

    kill "${HELD_PIDS[${#HELD_PIDS[@]} - 1]}" 2>/dev/null
    wait "${HELD_PIDS[${#HELD_PIDS[@]} - 1]}" 2>/dev/null || true
    out=$(FM_TMP_SWEEP_CHECKER="$checker" run_sweep "$root")
    assert_absent "$dir" "the same fixture must be reclaimed once no process holds it ($checker)"
    pass "sweep leaves a stale dir a live process holds open ($checker)"
  done
}

test_refuses_without_an_open_handle_check() {
  local root dir out
  root=$(new_root no-checker)
  dir=$(make_stale_dir "$root" fm-teardown-tests.Ee1122)

  out=$(FM_TMP_SWEEP_CHECKER=none run_sweep "$root")
  assert_present "$dir" "with no way to check open handles the sweep must remove nothing"
  assert_contains "$out" "cannot verify open handles" \
    "an unverifiable sweep must report why it reclaimed nothing"
  pass "sweep refuses to remove anything when open handles cannot be checked"
}

test_ignores_names_outside_the_convention() {
  local root out name
  root=$(new_root non-matching)
  for name in not-fm-tests.aB3xY9 fm-no-suffix fm-long-suffix.aB3xY99 fm-short.aB3xY; do
    make_stale_dir "$root" "$name" >/dev/null
  done
  printf 'file\n' > "$root/fm-a-file.aB3xY9"
  age_out "$root/fm-a-file.aB3xY9"

  out=$(run_sweep "$root")
  for name in not-fm-tests.aB3xY9 fm-no-suffix fm-long-suffix.aB3xY99 fm-short.aB3xY fm-a-file.aB3xY9; do
    assert_present "$root/$name" "the sweep must only match fm-<slug>.<6 chars> directories ($name)"
  done
  [ -z "$out" ] || fail "non-matching entries must not be reported, got: $out"
  pass "sweep ignores every name outside the scratch convention"
}

test_leaves_symlinked_candidate() {
  local root target out
  root=$(new_root symlink)
  target=$(make_stale_dir "$TMP_ROOT" fm-symlink-target.Ff3344)
  ln -s "$target" "$root/fm-teardown-tests.Gg5566"

  out=$(run_sweep "$root")
  assert_present "$target" "the sweep must never follow a symlink out of the temp root"
  assert_present "$root/fm-teardown-tests.Gg5566" "the symlink itself must be left alone"
  [ -z "$out" ] || fail "a symlinked candidate must not be reported, got: $out"
  rm -rf "$target"
  pass "sweep refuses to follow a symlinked candidate"
}

test_leaves_operational_home() {
  local root dir out
  root=$(new_root home-shaped)
  dir="$root/fm-idle-home.Hh7788"
  mkdir -p "$dir/state" "$dir/data" "$dir/config"
  age_out "$dir/state" "$dir/data" "$dir/config" "$dir"

  out=$(run_sweep "$root")
  assert_present "$dir" "an idle firstmate home in the temp root must never be swept"
  assert_contains "$out" "fm-idle-home.Hh7788: skipped: looks like a firstmate home" \
    "a home found in the temp root must be reported for hands-on attention"
  pass "sweep refuses a home-shaped directory and reports it"
}

test_leaves_dir_holding_the_live_home_or_cwd() {
  local root home_dir cwd_dir out
  root=$(new_root live-containment)
  home_dir=$(make_stale_dir "$root" fm-holds-home.Ii9900)
  cwd_dir=$(make_stale_dir "$root" fm-holds-cwd.Jj1122)
  mkdir -p "$home_dir/home" "$cwd_dir/work"
  age_out "$home_dir/home" "$home_dir" "$cwd_dir/work" "$cwd_dir"

  out=$(cd "$cwd_dir/work" && FM_TMP_SWEEP_ROOT="$root" FM_HOME="$home_dir/home" "$SWEEP")
  assert_present "$home_dir" "a dir containing the live FM_HOME must be left alone"
  assert_present "$cwd_dir" "a dir containing the live working directory must be left alone"
  [ -z "$out" ] || fail "live containment skips must stay silent, got: $out"
  pass "sweep leaves dirs that contain the live home or working directory"
}

test_dry_run_reports_without_removing() {
  local root dir out
  root=$(new_root dry-run)
  dir=$(make_stale_dir "$root" fm-teardown-tests.Kk3344)

  out=$(run_sweep "$root" --dry-run)
  assert_present "$dir" "--dry-run must not remove anything"
  assert_contains "$out" "fm-teardown-tests.Kk3344: removed (dry run)" \
    "--dry-run must still name what it would remove"
  pass "sweep --dry-run reports candidates without removing them"
}

test_age_window_is_configurable() {
  local root dir out
  root=$(new_root age-window)
  dir=$(make_fresh_dir "$root" fm-teardown-tests.Ll5566)

  out=$(run_sweep "$root" --age-hours 0)
  assert_absent "$dir" "--age-hours 0 must treat everything as stale"
  assert_contains "$out" "fm-teardown-tests.Ll5566: removed" "the removal must be reported"
  pass "sweep honours an explicit age window"
}

test_rejects_invalid_arguments() {
  local out code
  out=$(run_sweep "$TMP_ROOT" --age-hours nope 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "a non-numeric age window must be rejected"
  assert_contains "$out" "age hours must be a non-negative integer" \
    "an invalid age window must say what was wrong"

  out=$(run_sweep "$TMP_ROOT" --checker 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "an unknown argument must be rejected"
  pass "sweep rejects invalid arguments instead of guessing"
}

test_missing_root_is_a_silent_no_op() {
  local out code
  out=$(FM_TMP_SWEEP_ROOT="$TMP_ROOT/does-not-exist" "$SWEEP" 2>&1) && code=0 || code=$?
  expect_code 0 "$code" "an absent temp root must not fail the session start"
  [ -z "$out" ] || fail "an absent temp root must stay silent, got: $out"
  pass "sweep treats an absent temp root as a silent no-op"
}

test_removes_stale_scratch_dir
test_leaves_fresh_scratch_dir
test_leaves_dir_with_recent_deep_write
test_leaves_dir_held_open_by_live_process
test_refuses_without_an_open_handle_check
test_ignores_names_outside_the_convention
test_leaves_symlinked_candidate
test_leaves_operational_home
test_leaves_dir_holding_the_live_home_or_cwd
test_dry_run_reports_without_removing
test_age_window_is_configurable
test_rejects_invalid_arguments
test_missing_root_is_a_silent_no_op

echo "all fm-tmp-sweep tests passed"
