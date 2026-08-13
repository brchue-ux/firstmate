#!/usr/bin/env bash
# Behavior tests for fm-browser-sweep.sh, the session-start report of
# chrome-devtools-axi bridges no task is using any more.
#
# The sweep exists because the bridge detaches itself from the pane that started
# it, so nothing teardown kills can reach it. It reports and never stops, so the
# cases that matter are the ones proving it stays quiet: a bridge used within the
# window, a session a live task still owns, a recorded pid the process has since
# released, and a pid the OS reused for something that is not a bridge. Each case
# builds its own fake state root, so nothing here reads the host's real
# ~/.chrome-devtools-axi.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-browser-sweep)
SWEEP="$ROOT/bin/fm-browser-sweep.sh"

HELD_PIDS=()

# await_args <pid> <needle>: block until the process's command line is the one
# the fixture intends. A backgrounded script still shows its PARENT's command
# line between fork and exec, so a sweep run in that window reads the fixture as
# some other process and skips it - a flake that has nothing to do with the
# behavior under test.
await_args() {
  local pid=$1 needle=$2 attempt=0
  while [ "$attempt" -lt 200 ]; do
    case "$(ps -o args= -p "$pid" 2>/dev/null)" in
      *"$needle"*) return 0 ;;
    esac
    sleep 0.05
    attempt=$((attempt + 1))
  done
  fail "fixture process $pid never showed '$needle' in its command line"
}

cleanup_all() {
  local pid
  for pid in "${HELD_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  fm_test_cleanup
}
trap cleanup_all EXIT

# start_fake_bridge <dir>: a real, running process whose ps args carry the
# chrome-devtools-axi marker the sweep identifies bridges by. The name has to be
# in the command line for the identity check to be exercised honestly rather
# than stubbed out.
start_fake_bridge() {
  local dir=$1 script="$1/chrome-devtools-axi-bridge.js" pid
  mkdir -p "$dir"
  cat > "$script" <<'SH'
#!/usr/bin/env bash
sleep 300
SH
  chmod +x "$script"
  # Detached from this function's stdout: it is read through a command
  # substitution, and a background child holding that pipe open would make the
  # caller wait for the child instead of for the pid.
  "$script" >/dev/null 2>&1 &
  pid=$!
  HELD_PIDS+=("$pid")
  await_args "$pid" chrome-devtools-axi-bridge.js
  printf '%s\n' "$pid"
}

# start_fake_other <dir>: a running process that is NOT a bridge, for the
# reused-pid case.
start_fake_other() {
  local dir=$1 script="$1/unrelated-daemon" pid
  mkdir -p "$dir"
  cat > "$script" <<'SH'
#!/usr/bin/env bash
sleep 300
SH
  chmod +x "$script"
  "$script" >/dev/null 2>&1 &
  pid=$!
  HELD_PIDS+=("$pid")
  await_args "$pid" unrelated-daemon
  printf '%s\n' "$pid"
}

new_root() {
  local root="$TMP_ROOT/$1"
  mkdir -p "$root/sessions"
  printf '%s\n' "$root"
}

# write_session <root> <name> <pid>: the on-disk shape chrome-devtools-axi
# leaves for a running session - bridge.pid at the top level for the legacy
# "default" session, under sessions/<name>/ for a named one.
write_session() {
  local root=$1 name=$2 pid=$3 dir
  if [ "$name" = default ]; then
    dir=$root
  else
    dir="$root/sessions/$name"
  fi
  mkdir -p "$dir"
  printf '{"pid":%s,"port":9224}\n' "$pid" > "$dir/bridge.pid"
  printf '1\n' > "$dir/snapshot-generation"
  printf '%s\n' "$dir"
}

age_out() {
  touch -t 202601010000 "$@"
}

run_sweep() {
  local root=$1
  shift
  ( cd "$TMP_ROOT" && env -u FM_BROWSER_SWEEP_HOMES "$SWEEP" --root "$root" "$@" ) 2>&1
}

test_idle_bridge_is_reported_and_fresh_one_is_not() {
  local root idle_pid fresh_pid idle_dir out
  root=$(new_root idle-vs-fresh)
  idle_pid=$(start_fake_bridge "$root/proc")
  fresh_pid=$(start_fake_bridge "$root/proc")

  idle_dir=$(write_session "$root" fm-old-task "$idle_pid")
  age_out "$idle_dir/bridge.pid" "$idle_dir/snapshot-generation"
  write_session "$root" fm-live-task "$fresh_pid" >/dev/null

  out=$(run_sweep "$root" --age-hours 12)
  assert_contains "$out" "fm-old-task: idle: bridge pid $idle_pid unused for" \
    "an idle bridge was not reported"
  assert_contains "$out" "CHROME_DEVTOOLS_AXI_SESSION=fm-old-task chrome-devtools-axi stop" \
    "the reported line did not carry the session-scoped stop command"
  assert_not_contains "$out" "fm-live-task" \
    "a bridge used inside the window was reported"
  pass "fm-browser-sweep: reports a bridge idle past the window with its scoped stop command, and leaves a freshly used one alone"
}

test_live_task_session_is_protected() {
  local root pid dir home out
  root=$(new_root protected)
  home="$TMP_ROOT/protected-home"
  mkdir -p "$home/state"
  pid=$(start_fake_bridge "$root/proc")
  dir=$(write_session "$root" fm-paused-task "$pid")
  age_out "$dir/bridge.pid" "$dir/snapshot-generation"

  out=$(run_sweep "$root" --age-hours 12)
  assert_contains "$out" "fm-paused-task: idle:" \
    "an idle bridge with no owning task was not reported"

  fm_write_meta "$home/state/paused-task.meta" \
    "window=firstmate:fm-paused-task" "worktree=$home/wt" "project=$home/proj"
  out=$(run_sweep "$root" --age-hours 12 --protect-home "$home")
  assert_not_contains "$out" "fm-paused-task" \
    "a session a live task still records was reported as idle"
  pass "fm-browser-sweep: a session pinned to a task the home still records is never reported, however long it has sat"
}

test_dead_and_reused_pids_are_not_reported() {
  local root dead_pid other_pid dir out
  root=$(new_root pid-identity)

  dead_pid=$(start_fake_bridge "$root/proc")
  kill "$dead_pid" 2>/dev/null || true
  wait "$dead_pid" 2>/dev/null || true
  dir=$(write_session "$root" fm-dead-task "$dead_pid")
  age_out "$dir/bridge.pid" "$dir/snapshot-generation"

  other_pid=$(start_fake_other "$root/proc")
  dir=$(write_session "$root" fm-reused-task "$other_pid")
  age_out "$dir/bridge.pid" "$dir/snapshot-generation"

  out=$(run_sweep "$root" --age-hours 12)
  assert_not_contains "$out" "fm-dead-task" \
    "a bridge record whose process is gone was reported as a live orphan"
  assert_not_contains "$out" "fm-reused-task" \
    "a pid the OS reused for an unrelated process was reported as a bridge"
  pass "fm-browser-sweep: a released pid and a pid reused by a non-bridge process are both left alone"
}

test_default_session_is_examined_without_borrowing_named_activity() {
  local root pid named_dir out
  root=$(new_root default-session)
  pid=$(start_fake_bridge "$root/proc")
  printf '{"pid":%s,"port":9224}\n' "$pid" > "$root/bridge.pid"
  printf '1\n' > "$root/snapshot-generation"
  age_out "$root/bridge.pid" "$root/snapshot-generation"
  # A named session written now restamps the parent's directory mtime. That is
  # another session's activity, and counting it would hide the unpinned
  # "default" bridge that this whole fix exists to make visible.
  named_dir=$(write_session "$root" fm-other-task 1)

  out=$(run_sweep "$root" --age-hours 12)
  assert_contains "$out" "default: idle: bridge pid $pid unused for" \
    "the unpinned default session was not reported"
  [ -d "$named_dir" ] || fail "fixture named session directory was not created"
  pass "fm-browser-sweep: the unpinned default session is examined from its own state, not from a neighbor's"
}

test_unreadable_record_is_reported_and_missing_root_is_silent() {
  local root out
  root=$(new_root unreadable)
  mkdir -p "$root/sessions/fm-broken-task"
  printf 'not json\n' > "$root/sessions/fm-broken-task/bridge.pid"

  out=$(run_sweep "$root" --age-hours 12)
  assert_contains "$out" "fm-broken-task: skipped: bridge record names no readable pid" \
    "an unreadable bridge record was silently dropped"

  out=$(run_sweep "$TMP_ROOT/no-such-state-root" --age-hours 12)
  [ -z "$out" ] || fail "a missing state root must stay silent, got: $out"
  pass "fm-browser-sweep: an unreadable bridge record is surfaced, and a host with no browser state stays silent"
}

test_sweep_never_stops_a_session() {
  local root pid dir fakebin log out
  root=$(new_root read-only)
  fakebin=$(fm_fakebin "$root")
  log="$root/invocations.log"
  : > "$log"
  cat > "$fakebin/chrome-devtools-axi" <<SH
#!/usr/bin/env bash
printf 'session=%s args=%s\n' "\${CHROME_DEVTOOLS_AXI_SESSION:-}" "\$*" >> '$log'
exit 0
SH
  chmod +x "$fakebin/chrome-devtools-axi"

  pid=$(start_fake_bridge "$root/proc")
  dir=$(write_session "$root" fm-old-task "$pid")
  age_out "$dir/bridge.pid" "$dir/snapshot-generation"

  out=$(PATH="$fakebin:$PATH" run_sweep "$root" --age-hours 12)
  assert_contains "$out" "fm-old-task: idle:" "the idle bridge was not reported"
  [ ! -s "$log" ] || fail "the sweep invoked chrome-devtools-axi: $(cat "$log")"
  kill -0 "$pid" 2>/dev/null || fail "the sweep killed the reported bridge process"
  pass "fm-browser-sweep: reporting an idle bridge never runs chrome-devtools-axi and never kills the process"
}

test_idle_bridge_is_reported_and_fresh_one_is_not
test_live_task_session_is_protected
test_dead_and_reused_pids_are_not_reported
test_default_session_is_examined_without_borrowing_named_activity
test_unreadable_record_is_reported_and_missing_root_is_silent
test_sweep_never_stops_a_session
