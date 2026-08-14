#!/usr/bin/env bash
# Regression tests for cleanup endpoint identity validation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-endpoint-safety)
REAL_TMUX=$(command -v tmux || true)

make_case() {  # <name>
  local dir=$1
  mkdir -p "$TMP_ROOT/$dir/home/state" "$TMP_ROOT/$dir/home/data" \
    "$TMP_ROOT/$dir/home/config" "$TMP_ROOT/$dir/fakebin" \
    "$TMP_ROOT/$dir/worktree" "$TMP_ROOT/$dir/project"
  : > "$TMP_ROOT/$dir/worktree/sentinel"
  : > "$TMP_ROOT/$dir/runtime.log"
  cat > "$TMP_ROOT/$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  cat > "$TMP_ROOT/$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  cat > "$TMP_ROOT/$dir/fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
printf 'chrome-devtools-axi session=<%s>' "${CHROME_DEVTOOLS_AXI_SESSION-UNSET}" >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  chmod +x "$TMP_ROOT/$dir/fakebin/tmux" "$TMP_ROOT/$dir/fakebin/treehouse" \
    "$TMP_ROOT/$dir/fakebin/chrome-devtools-axi"
  printf '%s\n' "$TMP_ROOT/$dir"
}

# Each case gets its own chrome-devtools-axi state root, empty unless the case
# plants a bridge record in it. Cleanup only stops a session whose record still
# names a live bridge, so this is what decides whether the tool is called at all
# - and pointing it here keeps that decision off the developer's real browser
# state.
run_case() {  # <case> <id>
  local dir=$1 id=$2
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_BROWSER_SESSION_ROOT="$dir/browser-state" \
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" --force
}

BROWSER_HELD_PIDS=()

browser_pids_cleanup() {
  local pid
  for pid in "${BROWSER_HELD_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  return 0
}
trap browser_pids_cleanup EXIT

# A real running process whose command line carries the marker the tool itself
# identifies a bridge by, or one that deliberately does not. Cleanup reads the
# recorded pid's argv, so a stub would not exercise the guard at all.
start_marked_process() {  # <dir> <basename> -> pid
  local dir=$1 name=$2 script pid attempt=0
  mkdir -p "$dir"
  script="$dir/$name"
  printf '%s\n' '#!/usr/bin/env bash' 'sleep 300' > "$script"
  chmod +x "$script"
  "$script" >/dev/null 2>&1 &
  pid=$!
  BROWSER_HELD_PIDS+=("$pid")
  # A backgrounded script still shows its parent's command line between fork
  # and exec, so a read in that window sees the wrong process.
  while [ "$attempt" -lt 200 ]; do
    case "$(ps -o args= -p "$pid" 2>/dev/null)" in
      *"$name"*) printf '%s\n' "$pid"; return 0 ;;
    esac
    sleep 0.05
    attempt=$((attempt + 1))
  done
  fail "fixture process $pid never showed '$name' in its command line"
}

# The on-disk record chrome-devtools-axi leaves for a running named session.
write_bridge_record() {  # <case-dir> <session> <pid>
  local dir=$1 session=$2 pid=$3 state
  state="$dir/browser-state/sessions/$session"
  mkdir -p "$state"
  printf '{"pid":%s,"port":9224}\n' "$pid" > "$state/bridge.pid"
}

assert_refused_without_mutation() {  # <case> <id> <description>
  local dir=$1 id=$2 description=$3 rc
  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$description: teardown unexpectedly succeeded"
  assert_present "$dir/home/state/$id.meta" "$description: metadata changed before refusal"
  assert_present "$dir/worktree/sentinel" "$description: worktree changed before refusal"
  [ ! -s "$dir/runtime.log" ] || fail "$description: runtime command ran before refusal: $(cat "$dir/runtime.log")"
}

test_invalid_endpoint_records_refuse_before_mutation() {
  local dir id=endpoint-a

  dir=$(make_case missing)
  fm_write_meta "$dir/home/state/$id.meta" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "missing endpoint"

  dir=$(make_case empty)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=" "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "empty endpoint"

  dir=$(make_case malformed)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=ambient-current-window" "worktree=$dir/worktree" \
    "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "malformed endpoint"

  dir=$(make_case mismatched)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-other-task" "endpoint_task_id=other-task" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "task-mismatched endpoint"

  dir=$(make_case empty-binding)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "empty task binding"

  dir=$(make_case duplicate-binding)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "duplicate task binding"

  pass "fm-teardown: missing, empty, malformed, ambiguous, and task-mismatched endpoints refuse before every mutation or runtime call"
}

test_supported_backend_endpoint_records_validate() {
  local dir id backend target
  dir=$(make_case valid-backends)
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"

  id=tmux-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$dir/worktree" "project=$dir/project"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid tmux endpoint refused"
  [ "$FM_BACKEND_VALIDATED_BACKEND:$FM_BACKEND_VALIDATED_TARGET" = "tmux:firstmate:fm-$id" ] || fail "tmux endpoint validation returned wrong identity"

  id=tmux-spaced-session
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=team work:fm-$id" "worktree=$dir/worktree" "project=$dir/project"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid tmux endpoint with a spaced session name refused"
  [ "$FM_BACKEND_VALIDATED_TARGET" = "team work:fm-$id" ] || fail "tmux validation changed the spaced session identity"

  id=herdr-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:w1:p2" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=herdr" "herdr_session=lab" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid Herdr endpoint refused"

  id=zellij-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:7" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=zellij" "zellij_session=lab" "zellij_tab_id=3" "zellij_pane_id=7"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid Zellij endpoint refused"

  id=orca-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-7" \
    "worktree=$dir/worktree" "project=$dir/project" "backend=orca" "orca_worktree_id=worktree-9"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid Orca endpoint refused"
  [ "$FM_BACKEND_VALIDATED_TARGET" = term-7 ] || fail "Orca validation did not select its terminal"

  id=cmux-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=workspace-1:surface-2" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=cmux" "cmux_workspace_id=workspace-1" "cmux_surface_id=surface-2"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid cmux endpoint refused"

  for backend in tmux herdr zellij orca cmux; do
    set +e
    fm_backend_kill "$backend" "" >/dev/null 2>&1
    target=$?
    set -e
    [ "$target" -ne 0 ] || fail "$backend generic kill accepted an empty target"
  done
  pass "cleanup identity: valid tmux, Herdr, Zellij, Orca, and cmux records validate while every empty backend target refuses"
}

test_tmux_empty_target_refuses_without_invocation() {
  local dir rc
  dir=$(make_case direct-empty)
  set +e
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_kill ""' _ "$ROOT" \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "direct empty tmux target unexpectedly succeeded"
  [ ! -s "$dir/runtime.log" ] || fail "direct empty tmux target invoked tmux"
  pass "tmux backend: direct empty target returns nonzero without invoking tmux"
}

test_recorded_process_identity_cleanup_is_exact() {
  local dir target_pid control_pid target_record control_record live_command
  dir=$(make_case recorded-process)
  sleep 30 &
  control_pid=$!
  sleep 30 &
  target_pid=$!
  printf '%s\n' "$control_pid" > "$dir/control.pid"
  printf '%s\n' "$target_pid" > "$dir/target.pid"
  target_record=$(cat "$dir/target.pid")
  control_record=$(cat "$dir/control.pid")
  [ "$target_record" = "$target_pid" ] && [ "$control_record" = "$control_pid" ] \
    || fail "recorded process identity changed before cleanup"
  live_command=$(ps -p "$target_record" -o comm= 2>/dev/null | tr -d '[:space:]')
  case "$live_command" in sleep) ;; *) fail "recorded target pid no longer belongs to the expected child" ;; esac
  kill -TERM "$target_record"
  wait "$target_record" 2>/dev/null || true
  kill -0 "$target_record" 2>/dev/null && fail "exact target pid survived cleanup"
  kill -0 "$control_record" 2>/dev/null || fail "independent control process was disturbed"
  kill -TERM "$control_record"
  wait "$control_record" 2>/dev/null || true
  pass "process cleanup: creation-time PID identity removes only the exact child and preserves the control child"
}

# The chrome-devtools-axi bridge detaches itself from the pane at startup, so
# closing the endpoint and returning the worktree both miss it and it keeps a
# headless Chrome tree resident. Cleanup stops the session the brief pinned to
# this task - and only that one, because a bare stop would take down the default
# session, which belongs to whatever sibling home is using it right now.
test_browser_session_cleanup_is_scoped_to_the_task() {
  local dir id=browser-task other=browser-other invocations pid other_pid
  dir=$(make_case browser-session)
  # Both tasks have a live bridge on record, so a blanket stop has something to
  # hit and would show up as a second invocation rather than being inferred.
  pid=$(start_marked_process "$dir/proc" chrome-devtools-axi-bridge.js)
  write_bridge_record "$dir" "fm-$id" "$pid"
  other_pid=$(start_marked_process "$dir/proc" chrome-devtools-axi-bridge.js)
  write_bridge_record "$dir" "fm-$other" "$other_pid"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/nonexistent-worktree" "project=$dir/nonexistent-project" \
    "kind=scout" "mode=no-mistakes"
  # A second task's records, present throughout, so a blanket stop would be
  # visible as an extra invocation rather than inferred from absence.
  fm_write_meta "$dir/home/state/$other.meta" \
    "window=firstmate:fm-$other" "endpoint_task_id=$other" \
    "worktree=$dir/nonexistent-worktree" "project=$dir/nonexistent-project" \
    "kind=scout" "mode=no-mistakes"

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "scoped browser cleanup teardown failed: $(cat "$dir/stderr")"

  grep -Fqx "chrome-devtools-axi session=<fm-$id> <stop>" "$dir/runtime.log" \
    || fail "cleanup did not stop the task's own browser session: $(cat "$dir/runtime.log")"
  invocations=$(grep -c '^chrome-devtools-axi ' "$dir/runtime.log")
  [ "$invocations" -eq 1 ] \
    || fail "cleanup made $invocations browser calls, expected exactly one: $(cat "$dir/runtime.log")"
  grep '^chrome-devtools-axi ' "$dir/runtime.log" | grep -qv "session=<fm-$id>" \
    && fail "cleanup ran a browser command outside this task's session: $(cat "$dir/runtime.log")"
  assert_present "$dir/home/state/$other.meta" "cleanup disturbed an unrelated task's records"
  pass "fm-teardown: cleanup stops exactly the task's own pinned browser session and no other"
}

# A 64-character task id is legal, and fm-<id> would then be 67 - a name
# chrome-devtools-axi refuses, so the stop would silently reach nothing and the
# bridge would survive cleanup exactly as it did before this existed. The name
# has to be the one bin/fm-brief.sh briefed, which means the shared derivation,
# not a second spelling.
test_browser_session_cleanup_uses_the_shared_name_for_a_maximum_length_id() {
  local dir id session pid
  id="long-teardown-task-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  [ "${#id}" -eq 64 ] || fail "fixture task id is ${#id} characters, wanted 64"
  # shellcheck source=bin/fm-browser-session-lib.sh disable=SC1091
  . "$ROOT/bin/fm-browser-session-lib.sh"
  session=$(fm_browser_session_name "$id") || fail "no session name derived for a 64-character id"
  [ "${#session}" -le 64 ] \
    || fail "the shared derivation produced a ${#session}-character name: $session"

  dir=$(make_case browser-session-long)
  pid=$(start_marked_process "$dir/proc" chrome-devtools-axi-bridge.js)
  write_bridge_record "$dir" "$session" "$pid"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/nonexistent-worktree" "project=$dir/nonexistent-project" \
    "kind=scout" "mode=no-mistakes"

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "long-id browser cleanup teardown failed: $(cat "$dir/stderr")"

  grep -Fqx "chrome-devtools-axi session=<$session> <stop>" "$dir/runtime.log" \
    || fail "cleanup did not stop the derived session for a maximum-length id: $(cat "$dir/runtime.log")"
  grep -Fq "session=<fm-$id>" "$dir/runtime.log" \
    && fail "cleanup used a session name chrome-devtools-axi would refuse: $(cat "$dir/runtime.log")"
  pass "fm-teardown: a maximum-length task id is stopped under the shared derived session name, not an over-cap one"
}

# chrome-devtools-axi's own stop is not identity-guarded: it reads the recorded
# pid, checks only that it is alive, then SIGTERMs and SIGKILLs it. A bridge
# that crashed rather than stopped leaves its bridge.pid behind, so once that
# pid is reused, invoking stop at all is what kills an unrelated process - and
# unlike the sweep, cleanup runs with no operator in the loop. So cleanup must
# not reach the tool at all here.
test_browser_session_cleanup_skips_a_recorded_pid_that_is_not_a_bridge() {
  local dir id=browser-reused pid
  dir=$(make_case browser-session-reused)
  pid=$(start_marked_process "$dir/proc" unrelated-daemon)
  write_bridge_record "$dir" "fm-$id" "$pid"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/nonexistent-worktree" "project=$dir/nonexistent-project" \
    "kind=scout" "mode=no-mistakes"

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "reused-pid browser cleanup teardown failed: $(cat "$dir/stderr")"

  grep -q '^chrome-devtools-axi ' "$dir/runtime.log" \
    && fail "cleanup invoked the browser tool on a pid that is not a bridge: $(cat "$dir/runtime.log")"
  kill -0 "$pid" 2>/dev/null \
    || fail "cleanup killed the unrelated process holding the recorded pid"
  pass "fm-teardown: a recorded pid that is alive but is not a bridge is left alone, without invoking the browser tool"
}

# The record naming a pid that is simply gone is the other stale shape, and the
# tool would do nothing with it anyway.
test_browser_session_cleanup_skips_a_dead_recorded_pid() {
  local dir id=browser-dead pid
  dir=$(make_case browser-session-dead)
  pid=$(start_marked_process "$dir/proc" chrome-devtools-axi-bridge.js)
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  write_bridge_record "$dir" "fm-$id" "$pid"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/nonexistent-worktree" "project=$dir/nonexistent-project" \
    "kind=scout" "mode=no-mistakes"

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "dead-pid browser cleanup teardown failed: $(cat "$dir/stderr")"

  grep -q '^chrome-devtools-axi ' "$dir/runtime.log" \
    && fail "cleanup invoked the browser tool for a bridge that is already gone: $(cat "$dir/runtime.log")"
  pass "fm-teardown: a bridge record whose process is already gone does not reach the browser tool"
}

isolated_tmux_window_exists() {  # <dir> <socket> <session> <window>
  ( cd "$1" && "$REAL_TMUX" -S "$2" list-windows -t "$3" -F '#{window_name}' 2>/dev/null ) \
    | grep -Fqx "$4"
}

test_isolated_tmux_invalid_and_valid_cleanup() {
  local dir socket socket_id session='endpoint safety' target_id=target control=control target=fm-target
  local prefix_target=fm-prefix prefix_survivor=fm-prefix2 rc
  [ -n "$REAL_TMUX" ] || { echo "skip - tmux not installed"; return 0; }
  dir=$(make_case isolated-real)
  socket=dedicated.sock
  socket_id="$dir/$socket"
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-session -d -s "$session" -n "$control" )
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-window -d -t "$session:" -n "$target" )
  printf '%s\n' "$socket_id" > "$dir/socket.identity"
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
set -eu
[ -z "\${TMUX:-}" ] && [ -z "\${TMUX_PANE:-}" ] || exit 91
[ "\${FM_TEST_TMUX_SOCKET:-}" = '$socket_id' ] || exit 92
[ "\$(cat '$dir/socket.identity')" = '$socket_id' ] || exit 93
printf 'tmux' >> "\${FM_RUNTIME_LOG:?}"
printf ' <%s>' "\$@" >> "\${FM_RUNTIME_LOG:?}"
printf '\n' >> "\${FM_RUNTIME_LOG:?}"
cd '$dir'
exec '$REAL_TMUX' -S '$socket' "\$@"
SH
  chmod +x "$dir/fakebin/tmux"

  fm_write_meta "$dir/home/state/invalid.meta" \
    "window=" "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  set +e
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" invalid --force \
    > "$dir/invalid.out" 2> "$dir/invalid.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "isolated invalid endpoint unexpectedly succeeded"
  [ ! -s "$dir/runtime.log" ] || fail "isolated invalid endpoint reached tmux"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$control" || fail "invalid cleanup removed control window"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$target" || fail "invalid cleanup removed target window"

  set +e
  # shellcheck disable=SC2016 # $1 expands inside the isolated child shell.
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_kill ""' _ "$ROOT" \
    > "$dir/empty.out" 2> "$dir/empty.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "isolated direct empty target unexpectedly succeeded"
  [ ! -s "$dir/runtime.log" ] || fail "isolated direct empty target reached tmux"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$control" || fail "direct empty cleanup removed control window"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$target" || fail "direct empty cleanup removed target window"

  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-window -d -t "=$session:" -n "$prefix_survivor" )
  # shellcheck disable=SC2016 # $1 and $2 expand inside the isolated child shell.
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_kill "$2"' _ "$ROOT" "$session:$prefix_target"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$prefix_survivor" \
    || fail "missing exact target cleanup removed its prefix-matched neighbor"

  fm_write_meta "$dir/home/state/$target_id.meta" \
    "window=$session:$target" "endpoint_task_id=$target_id" \
    "worktree=$dir/nonexistent-worktree" "project=$dir/nonexistent-project" \
    "kind=scout" "mode=no-mistakes"
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$target_id" --force \
    > "$dir/valid.out" 2> "$dir/valid.err" \
    || fail "isolated valid endpoint teardown failed: $(cat "$dir/valid.err")"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$target" \
    && fail "valid cleanup did not remove the exact target window"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$control" \
    || fail "valid cleanup removed the independent control window"
  grep -Fqx "tmux <kill-window> <-t> <=$session:=$target>" "$dir/runtime.log" \
    || fail "valid cleanup did not invoke exactly the recorded target: $(cat "$dir/runtime.log")"

  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" kill-server 2>/dev/null ) || true
  pass "fm-teardown: exact tmux cleanup preserves invalid and prefix-matched neighbors while removing only the recorded target"
}

test_invalid_endpoint_records_refuse_before_mutation
test_supported_backend_endpoint_records_validate
test_tmux_empty_target_refuses_without_invocation
test_recorded_process_identity_cleanup_is_exact
test_browser_session_cleanup_is_scoped_to_the_task
test_browser_session_cleanup_uses_the_shared_name_for_a_maximum_length_id
test_browser_session_cleanup_skips_a_recorded_pid_that_is_not_a_bridge
test_browser_session_cleanup_skips_a_dead_recorded_pid
test_isolated_tmux_invalid_and_valid_cleanup
