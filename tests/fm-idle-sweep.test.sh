#!/usr/bin/env bash
# tests/fm-idle-sweep.test.sh - behavior of bin/fm-idle-sweep.sh, the heartbeat
# sweep that reclaims finished tasks still holding a pane or a worktree.
#
# The sweep's whole value rests on one claim: attempting cleanup automatically is
# safe because bin/fm-teardown.sh already refuses to discard work that has not
# landed. So the two halves are tested against a REAL fm-teardown.sh over real
# git fixtures, not a stub:
#   (a) done: + work landed on a remote          -> swept, task records gone
#   (b) done: + committed work on no remote      -> refused, everything preserved
#   (c) done: + uncommitted changes              -> refused, everything preserved
#
# Selection, backoff, and the never-force guarantee are then exercised against a
# recording teardown stub (FM_IDLE_SWEEP_TEARDOWN_BIN, a documented seam) so the
# assertion can be "teardown was never invoked" rather than "nothing changed",
# which a broken safety check would also satisfy:
#   (d) last status is working:                  -> never offered
#   (e) crew reconciles to parked at a gate      -> never offered
#   (f) kind=secondmate                          -> never offered
#   (g) nothing left to reclaim                  -> never offered
#   (h) repeat tick after a refusal              -> backed off, not re-offered
#   (i) status log moved after a refusal         -> offered again immediately
#   (j) every invocation                         -> exactly the task id, no --force
#   (k) --dry-run                                -> reports, invokes nothing
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SWEEP="$ROOT/bin/fm-idle-sweep.sh"
TMP_ROOT=$(fm_test_tmproot fm-idle-sweep-tests)
TASK=task-x1

# Build a sandbox holding one ship task:
#   $CASE/state/    firstmate state dir (task meta + status live here)
#   $CASE/data/     firstmate data dir
#   $CASE/fakebin/  treehouse/tmux/gh mocks plus a canned fm-crew-state.sh
#   $CASE/origin.git bare upstream, $CASE/project clone, $CASE/wt task worktree
# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/data" "$case_dir/config" "$fakebin"

  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  # Reports no windows, so an endpoint liveness read resolves to "missing".
  # Every case that must look live keeps its worktree directory instead.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  # No PR is associated with anything, keeping the landed-work check hermetic.
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  # Canned current-state reader. FM_FAKE_CREW_STATE fixes the verdict the sweep
  # reconciles against, the same seam bin/fm-classify-lib.sh documents.
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: done · source: status-log · done: finished}"
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh" \
    "$fakebin/fm-crew-state.sh"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b "fm/$TASK" "$case_dir/wt" main

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

# write_meta <case_dir> [mode] [kind]
write_meta() {
  local case_dir=$1 mode=${2:-no-mistakes} kind=${3:-ship}
  fm_write_meta "$case_dir/state/$TASK.meta" \
    "window=firstmate:fm-$TASK" \
    "endpoint_task_id=$TASK" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "harness=claude" \
    "kind=$kind" \
    "mode=$mode"
}

write_status() {  # <case_dir> <line>...
  local case_dir=$1
  shift
  printf '%s\n' "$@" > "$case_dir/state/$TASK.status"
}

wt_commit_file() {  # <case_dir> <file> <content>
  local case_dir=$1 file=$2 content=$3
  printf '%s\n' "$content" > "$case_dir/wt/$file"
  git -C "$case_dir/wt" add -- "$file"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "add $file"
}

# Push the task branch to origin and fetch it back, so the worktree's HEAD is
# reachable from a remote-tracking branch: teardown's definition of landed.
land_on_origin() {  # <case_dir>
  local case_dir=$1
  git -C "$case_dir/wt" push -q origin "fm/$TASK"
  git -C "$case_dir/project" fetch -q origin
}

# A teardown stand-in that records how it was called and never touches the fleet.
install_recording_teardown() {  # <case_dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/record-teardown" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/teardown.calls"
exit \${FM_FAKE_TEARDOWN_EXIT:-0}
SH
  chmod +x "$case_dir/fakebin/record-teardown"
  : > "$case_dir/teardown.calls"
}

teardown_call_count() {  # <case_dir>
  grep -c . "$1/teardown.calls" 2>/dev/null || true
}

run_sweep() {  # <case_dir> [args...]
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_CREW_STATE_BIN="$case_dir/fakebin/fm-crew-state.sh" \
  PATH="$case_dir/fakebin:$PATH" \
    "$SWEEP" "$@"
}

# Same, with teardown replaced by the recorder.
run_sweep_recording() {  # <case_dir> [args...]
  local case_dir=$1
  shift
  FM_IDLE_SWEEP_TEARDOWN_BIN="$case_dir/fakebin/record-teardown" \
    run_sweep "$case_dir" "$@"
}

# --- (a) the confirmed root cause: a finished, landed task is reclaimed -------

test_finished_landed_task_is_swept() {
  local case_dir out
  case_dir=$(make_case landed-swept)
  write_meta "$case_dir"
  wt_commit_file "$case_dir" fix.txt "the fix"
  land_on_origin "$case_dir"
  write_status "$case_dir" "done: PR https://example.test/pr/9 checks green"

  out=$(run_sweep "$case_dir" --verbose) || fail "landed-swept: sweep exited non-zero"

  assert_contains "$out" "$TASK: cleaned up" "landed-swept: sweep did not report the cleanup"
  assert_absent "$case_dir/state/$TASK.meta" "landed-swept: task metadata survived the sweep"
  assert_absent "$case_dir/state/$TASK.status" "landed-swept: task status log survived the sweep"
  assert_absent "$case_dir/state/.idle-sweep-$TASK" \
    "landed-swept: backoff record left behind after a successful cleanup"
  pass "a finished task whose work landed is cleaned up without anyone asking"
}

# --- (b) and (c): the safety gate that makes (a) safe to automate -------------

test_unlanded_done_task_is_left_alone() {
  local case_dir out
  case_dir=$(make_case unlanded-kept)
  write_meta "$case_dir"
  # Committed but pushed nowhere, and no PR: teardown's refusal case.
  wt_commit_file "$case_dir" fix.txt "the fix"
  write_status "$case_dir" "done: PR https://example.test/pr/9 checks green"

  out=$(run_sweep "$case_dir" --verbose) || fail "unlanded-kept: sweep exited non-zero"

  assert_contains "$out" "$TASK: refused:" "unlanded-kept: sweep did not report the refusal"
  assert_not_contains "$out" "$TASK: cleaned up" "unlanded-kept: sweep claimed a cleanup it did not do"
  assert_present "$case_dir/state/$TASK.meta" "unlanded-kept: task metadata was removed despite unlanded work"
  assert_present "$case_dir/wt/fix.txt" "unlanded-kept: unlanded work was discarded"
  pass "a task reporting done: whose work has not landed is refused and preserved"
}

test_dirty_worktree_is_left_alone() {
  local case_dir out
  case_dir=$(make_case dirty-kept)
  write_meta "$case_dir"
  wt_commit_file "$case_dir" fix.txt "the fix"
  land_on_origin "$case_dir"
  printf 'work in progress\n' > "$case_dir/wt/scratch.txt"
  write_status "$case_dir" "done: PR https://example.test/pr/9 checks green"

  out=$(run_sweep "$case_dir" --verbose) || fail "dirty-kept: sweep exited non-zero"

  assert_contains "$out" "$TASK: refused:" "dirty-kept: sweep did not report the refusal"
  assert_present "$case_dir/state/$TASK.meta" "dirty-kept: task metadata was removed despite uncommitted changes"
  assert_present "$case_dir/wt/scratch.txt" "dirty-kept: uncommitted changes were discarded"
  pass "landed commits do not make a dirty worktree sweepable"
}

# --- (d)-(g): what is never offered to teardown at all ------------------------

test_unfinished_task_is_never_offered() {
  local case_dir out
  case_dir=$(make_case working-skipped)
  write_meta "$case_dir"
  install_recording_teardown "$case_dir"
  wt_commit_file "$case_dir" fix.txt "the fix"
  land_on_origin "$case_dir"
  write_status "$case_dir" "working: still implementing"

  out=$(run_sweep_recording "$case_dir" --verbose) || fail "working-skipped: sweep exited non-zero"

  [ "$(teardown_call_count "$case_dir")" -eq 0 ] \
    || fail "working-skipped: cleanup was attempted for a task that is still working"
  assert_contains "$out" "$TASK: skipped:" "working-skipped: sweep did not report the skip"
  pass "a task still reporting working: is never offered for cleanup, landed or not"
}

test_parked_crew_is_never_offered() {
  local case_dir out
  case_dir=$(make_case parked-skipped)
  write_meta "$case_dir"
  install_recording_teardown "$case_dir"
  wt_commit_file "$case_dir" fix.txt "the fix"
  land_on_origin "$case_dir"
  # The stale-log case AGENTS.md warns about: a done: event followed by a crew
  # that is really parked at a gate waiting on a decision.
  write_status "$case_dir" "done: PR https://example.test/pr/9 checks green"

  out=$(FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at ask-user: 1 finding(s)' \
    run_sweep_recording "$case_dir" --verbose) || fail "parked-skipped: sweep exited non-zero"

  [ "$(teardown_call_count "$case_dir")" -eq 0 ] \
    || fail "parked-skipped: cleanup was attempted for a crew parked at a gate"
  assert_contains "$out" "$TASK: skipped: currently parked" \
    "parked-skipped: sweep did not report the current-state skip"
  pass "a stale done: line never outranks a crew reconciled to parked at a gate"
}

test_secondmate_is_never_offered() {
  local case_dir out
  case_dir=$(make_case secondmate-skipped)
  write_meta "$case_dir" secondmate secondmate
  install_recording_teardown "$case_dir"
  write_status "$case_dir" "done: routed work finished"

  out=$(run_sweep_recording "$case_dir" --verbose) || fail "secondmate-skipped: sweep exited non-zero"

  [ "$(teardown_call_count "$case_dir")" -eq 0 ] \
    || fail "secondmate-skipped: the sweep tried to retire a persistent secondmate"
  assert_contains "$out" "$TASK: skipped: secondmates" \
    "secondmate-skipped: sweep did not report why the secondmate was left alone"
  assert_present "$case_dir/state/$TASK.meta" "secondmate-skipped: secondmate records were disturbed"
  pass "a persistent secondmate is never retired by the periodic sweep"
}

test_task_with_nothing_to_reclaim_is_never_offered() {
  local case_dir out
  case_dir=$(make_case nothing-to-reclaim)
  write_meta "$case_dir"
  install_recording_teardown "$case_dir"
  write_status "$case_dir" "failed: the build never came back"
  # No worktree on disk, and the mock reports no live window for the endpoint.
  git -C "$case_dir/project" worktree remove --force "$case_dir/wt"

  out=$(run_sweep_recording "$case_dir" --verbose) || fail "nothing-to-reclaim: sweep exited non-zero"

  [ "$(teardown_call_count "$case_dir")" -eq 0 ] \
    || fail "nothing-to-reclaim: cleanup was attempted with no worktree or endpoint left"
  assert_contains "$out" "$TASK: skipped: no worktree or live endpoint" \
    "nothing-to-reclaim: sweep did not report the skip"
  pass "a task holding neither a worktree nor a live endpoint is left to the recovery path"
}

test_failed_task_with_live_worktree_is_swept() {
  local case_dir out
  case_dir=$(make_case failed-swept)
  write_meta "$case_dir"
  wt_commit_file "$case_dir" fix.txt "the attempt"
  land_on_origin "$case_dir"
  write_status "$case_dir" "failed: validation could not be completed"

  out=$(run_sweep "$case_dir" --verbose) || fail "failed-swept: sweep exited non-zero"

  assert_contains "$out" "$TASK: cleaned up" "failed-swept: a failed task with landed work was not reclaimed"
  assert_absent "$case_dir/state/$TASK.meta" "failed-swept: task metadata survived the sweep"
  pass "a failed task is reclaimed on the same terms as a done one"
}

# --- (h) and (i): backoff, so a still-landing task is not re-attempted forever -

test_refused_task_backs_off_on_the_next_tick() {
  local case_dir out
  case_dir=$(make_case backoff-quiet)
  write_meta "$case_dir"
  wt_commit_file "$case_dir" fix.txt "the fix"
  write_status "$case_dir" "done: PR https://example.test/pr/9 checks green"

  run_sweep "$case_dir" --verbose > /dev/null || fail "backoff-quiet: first sweep exited non-zero"
  assert_present "$case_dir/state/.idle-sweep-$TASK" "backoff-quiet: the refusal was not recorded"

  install_recording_teardown "$case_dir"
  out=$(run_sweep_recording "$case_dir" --verbose) || fail "backoff-quiet: second sweep exited non-zero"

  [ "$(teardown_call_count "$case_dir")" -eq 0 ] \
    || fail "backoff-quiet: an unchanged refused task was re-attempted on the very next tick"
  assert_contains "$out" "$TASK: skipped: waiting out the retry window" \
    "backoff-quiet: sweep did not report the backoff"
  pass "a task that keeps refusing is not re-attempted on every heartbeat"
}

test_new_evidence_reopens_a_backed_off_task() {
  local case_dir out
  case_dir=$(make_case backoff-reopen)
  write_meta "$case_dir"
  wt_commit_file "$case_dir" fix.txt "the fix"
  write_status "$case_dir" "done: PR https://example.test/pr/9 checks green"

  run_sweep "$case_dir" --verbose > /dev/null || fail "backoff-reopen: first sweep exited non-zero"

  install_recording_teardown "$case_dir"
  # The task moved: a new status event is new evidence, so the retry window
  # reopens immediately instead of waiting out --retry-secs.
  printf '%s\n' "done: PR https://example.test/pr/9 merged" >> "$case_dir/state/$TASK.status"
  out=$(run_sweep_recording "$case_dir" --verbose) || fail "backoff-reopen: second sweep exited non-zero"

  [ "$(teardown_call_count "$case_dir")" -eq 1 ] \
    || fail "backoff-reopen: a task with a new status event was not re-offered ($out)"
  pass "new evidence on a refused task reopens its retry window immediately"
}

test_elapsed_retry_window_reopens_a_backed_off_task() {
  local case_dir
  case_dir=$(make_case backoff-elapsed)
  write_meta "$case_dir"
  wt_commit_file "$case_dir" fix.txt "the fix"
  write_status "$case_dir" "done: PR https://example.test/pr/9 checks green"

  run_sweep "$case_dir" --verbose > /dev/null || fail "backoff-elapsed: first sweep exited non-zero"

  install_recording_teardown "$case_dir"
  run_sweep_recording "$case_dir" --retry-secs 0 --verbose > /dev/null \
    || fail "backoff-elapsed: second sweep exited non-zero"

  [ "$(teardown_call_count "$case_dir")" -eq 1 ] \
    || fail "backoff-elapsed: an elapsed retry window did not reopen the task"
  pass "a refused task is retried once its retry window elapses, with nothing else changed"
}

# --- (j) and (k): the invocation contract -------------------------------------

test_teardown_is_never_forced() {
  local case_dir calls
  case_dir=$(make_case never-forced)
  write_meta "$case_dir"
  install_recording_teardown "$case_dir"
  wt_commit_file "$case_dir" fix.txt "the fix"
  write_status "$case_dir" "done: PR https://example.test/pr/9 checks green"

  run_sweep_recording "$case_dir" --verbose > /dev/null || fail "never-forced: sweep exited non-zero"

  calls=$(cat "$case_dir/teardown.calls")
  [ "$calls" = "$TASK" ] \
    || fail "never-forced: sweep invoked cleanup with something other than the bare task id: '$calls'"
  pass "the sweep only ever asks for a plain cleanup, never a forced one"
}

test_dry_run_changes_nothing() {
  local case_dir out
  case_dir=$(make_case dry-run)
  write_meta "$case_dir"
  install_recording_teardown "$case_dir"
  wt_commit_file "$case_dir" fix.txt "the fix"
  land_on_origin "$case_dir"
  write_status "$case_dir" "done: PR https://example.test/pr/9 checks green"

  out=$(run_sweep_recording "$case_dir" --dry-run --verbose) || fail "dry-run: sweep exited non-zero"

  assert_contains "$out" "$TASK: would clean up" "dry-run: sweep did not report the candidate"
  [ "$(teardown_call_count "$case_dir")" -eq 0 ] || fail "dry-run: sweep invoked cleanup anyway"
  assert_present "$case_dir/state/$TASK.meta" "dry-run: task metadata was removed"
  assert_absent "$case_dir/state/.idle-sweep-$TASK" "dry-run: sweep wrote a backoff record"
  pass "--dry-run reports the candidate and changes nothing"
}

test_quiet_by_default() {
  local case_dir out
  case_dir=$(make_case quiet-default)
  write_meta "$case_dir"
  install_recording_teardown "$case_dir"
  wt_commit_file "$case_dir" fix.txt "the fix"
  write_status "$case_dir" "working: still implementing"

  out=$(run_sweep_recording "$case_dir") || fail "quiet-default: sweep exited non-zero"

  [ -z "$out" ] || fail "quiet-default: a sweep with nothing to reclaim printed: $out"
  pass "a sweep with nothing to reclaim says nothing"
}

test_finished_landed_task_is_swept
test_unlanded_done_task_is_left_alone
test_dirty_worktree_is_left_alone
test_unfinished_task_is_never_offered
test_parked_crew_is_never_offered
test_secondmate_is_never_offered
test_task_with_nothing_to_reclaim_is_never_offered
test_failed_task_with_live_worktree_is_swept
test_refused_task_backs_off_on_the_next_tick
test_new_evidence_reopens_a_backed_off_task
test_elapsed_retry_window_reopens_a_backed_off_task
test_teardown_is_never_forced
test_dry_run_changes_nothing
test_quiet_by_default
