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
  # Real home content, not just the directory layout: an idle home can sit
  # unwritten past the age window, so this is what has to protect it.
  printf '# Backlog\n' > "$dir/data/backlog.md"
  age_out "$dir/data/backlog.md" "$dir/state" "$dir/data" "$dir/config" "$dir"

  out=$(run_sweep "$root")
  assert_present "$dir" "an idle firstmate home in the temp root must never be swept"
  assert_contains "$out" "fm-idle-home.Hh7788: skipped: looks like a firstmate home" \
    "a home found in the temp root must be reported for hands-on attention"
  pass "sweep refuses a home with real content and reports it"
}

test_leaves_home_carrying_only_the_identity_marker() {
  local root dir out
  root=$(new_root home-marker)
  dir="$root/fm-marked-home.Mm2244"
  mkdir -p "$dir"
  : > "$dir/.fm-secondmate-home"
  age_out "$dir/.fm-secondmate-home" "$dir"

  out=$(run_sweep "$root")
  assert_present "$dir" "the seeded secondmate identity marker alone must protect a home"
  assert_contains "$out" "fm-marked-home.Mm2244: skipped: looks like a firstmate home" \
    "a marked home found in the temp root must be reported for hands-on attention"
  pass "sweep refuses a directory carrying the secondmate home marker"
}

# The exact shape tests/fm-backend-autodetect-smoke.test.sh leaves behind when it
# is killed: a scratch root whose top level holds state/, data/ and config/. That
# layout alone must never buy a permanent exemption, or the orphan this sweep
# exists for is the one orphan it can never reclaim.
test_reclaims_scratch_shaped_like_a_home_but_empty() {
  local root dir out
  root=$(new_root home-shaped-scratch)
  dir="$root/fm-backend-autodetect-smoke.Nn6688"
  mkdir -p "$dir/state" "$dir/data" "$dir/config"
  age_out "$dir/state" "$dir/data" "$dir/config" "$dir"

  out=$(run_sweep "$root")
  assert_absent "$dir" "bare state/, data/ and config/ dirs are a fixture shape, not a home"
  assert_contains "$out" "fm-backend-autodetect-smoke.Nn6688: removed" \
    "the reclaimed fixture must be reported like any other removal"
  pass "sweep reclaims a stale fixture whose layout only resembles a home"
}

test_exhausted_budget_defers_every_remaining_candidate() {
  local root first second out
  root=$(new_root budget)
  first=$(make_stale_dir "$root" fm-teardown-tests.Oo1357)
  second=$(make_stale_dir "$root" fm-teardown-tests.Pp2468)

  out=$(run_sweep "$root" --timeout 0)
  assert_present "$first" "a sweep with no time budget left must remove nothing"
  assert_present "$second" "a sweep with no time budget left must remove nothing"
  assert_contains "$out" "sweep budget exhausted after removing 0, 2 candidate(s) deferred" \
    "an exhausted budget must report exactly how much work it handed to the next session"
  assert_not_contains "$out" ": removed" "a deferred candidate must not be reported as removed"
  pass "sweep defers every remaining candidate once its time budget is exhausted"
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

# make_home <dir> <task id> <tasktmp>: a firstmate home whose task records name
# <tasktmp> as a live task's scratch root.
make_home() {
  local home=$1 id=$2 tasktmp=$3
  mkdir -p "$home/state" "$home/data"
  printf 'window=w\ntasktmp=%s\n' "$tasktmp" > "$home/state/$id.meta"
  printf '%s\n' "$home"
}

test_leaves_a_live_tasks_scratch_root() {
  local root home live orphan out
  root=$(new_root live-task)
  # A task id ending in a dot plus six alphanumerics is shaped exactly like a
  # mktemp fixture, which is the only way a live scratch root reaches the
  # candidate list at all.
  live=$(make_stale_dir "$root" fm-report.v2beta)
  orphan=$(make_stale_dir "$root" fm-teardown-tests.aB3xY9)
  home=$(make_home "$TMP_ROOT/live-task-home" report.v2beta "$live")

  out=$(run_sweep "$root" --protect-homes "$home")
  assert_present "$live" "a scratch root a home records as a live task must never be removed"
  assert_absent "$orphan" "an ordinary orphan beside it must still be reclaimed"
  assert_contains "$out" "fm-report.v2beta: skipped: a firstmate home records it as a live task's scratch root" \
    "refusing a live task's scratch must be reported"
  pass "sweep never removes a scratch root a home records as a live task's"
}

test_leaves_a_task_scratch_root_carrying_gotmp() {
  local root dir out
  root=$(new_root gotmp)
  dir=$(make_stale_dir "$root" fm-someid.aB3xY9)
  mkdir -p "$dir/gotmp"
  age_out "$dir/gotmp" "$dir"

  out=$(run_sweep "$root")
  assert_present "$dir" "a per-task scratch root carrying gotmp/ must never be removed"
  assert_contains "$out" "fm-someid.aB3xY9: skipped: looks like a live task's scratch root" \
    "refusing a per-task scratch root must be reported"
  pass "sweep never removes a per-task scratch root carrying gotmp/"
}

test_refuses_when_task_records_cannot_be_read() {
  local root home dir out
  if [ "$(id -u)" = 0 ]; then
    pass "unreadable task records: root bypasses directory permissions, nothing to assert"
    return 0
  fi
  root=$(new_root unreadable-records)
  dir=$(make_stale_dir "$root" fm-teardown-tests.aB3xY9)
  home=$(make_home "$TMP_ROOT/unreadable-home" sometask /nowhere)
  chmod 000 "$home/state"

  out=$(run_sweep "$root" --protect-homes "$home")
  chmod 755 "$home/state"
  assert_present "$dir" \
    "an unreadable task record must stop the sweep rather than let it guess"
  assert_contains "$out" "task records could not be read" \
    "refusing on unreadable task records must say so"
  pass "sweep refuses entirely when a home's task records cannot be read"
}

test_reads_secondmate_homes_for_live_scratch() {
  local root primary second live out
  root=$(new_root secondmate-task)
  live=$(make_stale_dir "$root" fm-second.aB3xY9)
  second=$(make_home "$TMP_ROOT/second-home" second.aB3xY9 "$live")
  primary="$TMP_ROOT/primary-home"
  mkdir -p "$primary/data" "$primary/state"
  printf -- '- second (home: %s; scope: things)\n' "$second" > "$primary/data/secondmates.md"

  out=$(run_sweep "$root" --protect-homes "$primary")
  assert_present "$live" \
    "a live task recorded by a registered secondmate home must be protected too"
  assert_contains "$out" "fm-second.aB3xY9: skipped: a firstmate home records it" \
    "protecting a secondmate's live task must be reported"
  pass "sweep reads registered secondmate homes for live task scratch"
}

test_unreadable_secondmate_registry_refuses_the_sweep() {
  local root dir home out
  if [ "$(id -u)" = 0 ]; then
    pass "unreadable secondmate registry: root bypasses file permissions, nothing to assert"
    return 0
  fi
  root=$(new_root unreadable-registry)
  dir=$(make_stale_dir "$root" fm-teardown-tests.aB3xY9)
  home="$TMP_ROOT/unreadable-registry-home"
  mkdir -p "$home/state" "$home/data"
  printf -- '- second (home: %s; scope: things)\n' "$TMP_ROOT/second" > "$home/data/secondmates.md"
  chmod 000 "$home/data/secondmates.md"

  out=$(run_sweep "$root" --protect-homes "$home")
  chmod 644 "$home/data/secondmates.md"
  # A registry that is simply absent says the home has no secondmates, which
  # every other case here relies on. One that exists and cannot be read hides a
  # whole class of homes, so the live tasks they record go unseen - the same
  # ambiguity as an unreadable task record, and it must refuse the same way.
  assert_present "$dir" \
    "an unreadable secondmate registry must stop the sweep rather than let it guess"
  # Naming the wrong records sends the operator to inspect state/ and find
  # nothing wrong, which is the same misdirection as reporting a candidate cap
  # as an exhausted time budget.
  assert_contains "$out" "directory or secondmate registry could not be read" \
    "refusing on an unreadable registry must name the registry, not task records"
  assert_not_contains "$out" "task records could not be read" \
    "an unreadable registry must not be reported as an unreadable task record"
  pass "sweep refuses entirely when a home's secondmate registry cannot be read"
}

test_unsearchable_home_root_refuses_the_sweep() {
  local root dir home out
  if [ "$(id -u)" = 0 ]; then
    pass "unsearchable home root: root bypasses directory permissions, nothing to assert"
    return 0
  fi
  root=$(new_root unsearchable-home)
  dir=$(make_stale_dir "$root" fm-teardown-tests.aB3xY9)
  home=$(make_home "$TMP_ROOT/unsearchable-home-root" sometask "$TMP_ROOT/nowhere")
  chmod 000 "$home"

  out=$(run_sweep "$root" --protect-homes "$home")
  chmod 755 "$home"
  # From outside, a home with no search permission is indistinguishable from a
  # home that simply has no state/ - so without refusing, every live task it
  # records would go unprotected while the sweep reported a clean run.
  assert_present "$dir" \
    "a home that exists but cannot be searched must stop the sweep, not be skipped"
  assert_contains "$out" "directory or secondmate registry could not be read" \
    "refusing on an unsearchable home must name the home, not task records"
  pass "sweep refuses entirely when a home exists but cannot be searched"
}

test_name_prefix_narrows_the_candidate_set() {
  local root scoped unscoped outside out
  root=$(new_root name-prefix)
  scoped=$(make_stale_dir "$root" fm-test-run.aB3xY9)
  unscoped=$(make_stale_dir "$root" fm-other-tool.Cc44Dd)
  # Outside the naming convention entirely: a prefix must narrow what the
  # convention already allowed, never reach past it.
  outside="$root/test-run.Ee55Ff"
  mkdir -p "$outside"
  age_out "$outside"

  out=$(run_sweep "$root" --name-prefix fm-test-run.)
  assert_absent "$scoped" "a candidate matching the prefix must still be reclaimed"
  assert_present "$unscoped" \
    "a stale candidate outside the prefix must be left to an unscoped pass: $unscoped"
  assert_present "$outside" "a prefix must never widen the sweep past the name convention"
  assert_contains "$out" "fm-test-run.aB3xY9: removed" "the scoped removal must be reported"
  pass "sweep --name-prefix narrows the candidate set and cannot widen it"
}

test_protects_a_live_task_recorded_through_a_symlinked_root() {
  local root real live recorded home out
  real=$(new_root symlinked-root-real)
  root="$TMP_ROOT/symlinked-root"
  ln -s "$real" "$root"
  live=$(make_stale_dir "$real" fm-symtask.aB3xY9)
  # What bin/fm-spawn.sh records on a host whose temp root is a symlink - macOS,
  # where /tmp points at /private/tmp. Candidates always carry the resolved
  # root, so a verbatim comparison can never match and the protection would be
  # inert on exactly the hosts where the two spellings differ.
  recorded="$root/fm-symtask.aB3xY9"
  home=$(make_home "$TMP_ROOT/symlinked-root-home" symtask.aB3xY9 "$recorded")

  out=$(run_sweep "$root" --protect-homes "$home")
  assert_present "$live" \
    "a live task recorded through a symlinked temp root must still be protected"
  assert_contains "$out" "fm-symtask.aB3xY9: skipped: a firstmate home records it" \
    "protecting a live task through a symlinked root must be reported"
  pass "sweep resolves recorded task scratch before comparing it to a candidate"
}

test_age_minutes_window() {
  local root recent out
  root=$(new_root age-minutes)
  recent=$(make_fresh_dir "$root" fm-recent.aB3xY9)
  # Ten minutes old: stale under a 5-minute window, fresh under the 12h default.
  touch -d '10 minutes ago' "$recent/nested/payload" "$recent/nested" "$recent" 2>/dev/null \
    || touch -A -001000 "$recent/nested/payload" "$recent/nested" "$recent"

  out=$(run_sweep "$root" --age-minutes 5)
  assert_absent "$recent" "a dir past the minutes window must be reclaimed"
  assert_contains "$out" "fm-recent.aB3xY9: removed" "the minutes window must report its removal"
  pass "sweep honours a minutes-granularity age window"
}

test_max_bounds_the_examination() {
  local root out i
  root=$(new_root max-bound)
  for i in 1 2 3; do
    make_stale_dir "$root" "fm-bounded$i.aB3xY9" >/dev/null
  done

  out=$(run_sweep "$root" --max 1)
  [ "$(find "$root" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 2 ] \
    || fail "--max 1 must examine exactly one candidate and defer the rest"
  # The reason matters as much as the count: an operator told the time budget
  # ran out goes looking for a slow host instead of for the cap they set.
  assert_contains "$out" "the --max 1 candidate cap was reached after removing 1, 2 candidate(s) deferred" \
    "a bounded sweep must name the cap it stopped on"
  assert_not_contains "$out" "budget exhausted" \
    "the candidate cap must never be reported as the time budget"
  pass "sweep stops after --max candidates and reports the cap as the reason"
}

# The session-start sweep is bounded only by its time budget, and must stay that
# way: capping it by default would strand orphans on exactly the host that
# leaked the most, which is the host this sweep exists for. The bound belongs to
# the caller that wants it - bin/fm-test-run.sh passes its own --max.
test_default_max_is_unbounded() {
  local root out i
  local -a dirs=()
  root=$(new_root unbounded-default)
  i=1
  while [ "$i" -le 501 ]; do
    dirs+=("$root/fm-bulk$i.aB3xY9")
    i=$((i + 1))
  done
  mkdir -p "${dirs[@]}"
  age_out "${dirs[@]}"

  # A generous budget, so this measures the candidate bound and nothing else.
  out=$(run_sweep "$root" --timeout 600)
  [ "$(find "$root" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 0 ] \
    || fail "the default sweep must examine more than 500 candidates, not cap itself"
  assert_not_contains "$out" "deferred" \
    "an unbounded sweep with time to spare must defer nothing"
  pass "sweep examines every candidate by default and bounds only when asked"
}

test_removes_stale_scratch_dir
test_leaves_fresh_scratch_dir
test_leaves_dir_with_recent_deep_write
test_leaves_dir_held_open_by_live_process
test_refuses_without_an_open_handle_check
test_ignores_names_outside_the_convention
test_leaves_symlinked_candidate
test_leaves_operational_home
test_leaves_home_carrying_only_the_identity_marker
test_reclaims_scratch_shaped_like_a_home_but_empty
test_exhausted_budget_defers_every_remaining_candidate
test_leaves_dir_holding_the_live_home_or_cwd
test_dry_run_reports_without_removing
test_age_window_is_configurable
test_rejects_invalid_arguments
test_missing_root_is_a_silent_no_op
test_leaves_a_live_tasks_scratch_root
test_leaves_a_task_scratch_root_carrying_gotmp
test_refuses_when_task_records_cannot_be_read
test_reads_secondmate_homes_for_live_scratch
test_age_minutes_window
test_max_bounds_the_examination
test_default_max_is_unbounded
test_unreadable_secondmate_registry_refuses_the_sweep
test_unsearchable_home_root_refuses_the_sweep
test_name_prefix_narrows_the_candidate_set
test_protects_a_live_task_recorded_through_a_symlinked_root

echo "all fm-tmp-sweep tests passed"
