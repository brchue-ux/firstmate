#!/usr/bin/env bash
# Behavior tests for fm-browser-sweep.sh, the session-start report of
# chrome-devtools-axi bridges no task is using any more.
#
# The sweep exists because the bridge detaches itself from the pane that started
# it, so nothing teardown kills can reach it. It reports and never stops, so the
# cases that matter are the ones proving it stays quiet: a bridge used within the
# window, a session a live task still owns anywhere in the fleet, a recorded pid
# the process has since released, and a pid the OS reused for something that is
# not a bridge. Each case builds its own fake state root and its own fixture
# fleet, so nothing here reads the host's real ~/.chrome-devtools-axi or the
# developer's own backlog.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The sweep refuses to report anything it cannot check against the fleet's open
# work, and that index is built with jq.
command -v jq >/dev/null 2>&1 || {
  echo "skip: jq not found"
  exit 0
}

TMP_ROOT=$(fm_test_tmproot fm-browser-sweep)
SWEEP="$ROOT/bin/fm-browser-sweep.sh"

# The session name is derived, never spelled out, for the same reason the sweep
# derives it: a long task id produces a shortened name with no id inside it.
# shellcheck source=bin/fm-browser-session-lib.sh disable=SC1091
. "$ROOT/bin/fm-browser-session-lib.sh"

# A fixture fleet: this home plus one registered secondmate home carrying the
# open work. Nothing in this home's own backlog is open, so a session that is
# protected here is protected because of ANOTHER home's live worker - the case
# --protect-home alone can never see, since bridge state is host-global.
FLEET_MAIN="$TMP_ROOT/fleet-main"
FLEET_MATE="$TMP_ROOT/fleet-mate"
mkdir -p "$FLEET_MAIN/data" "$FLEET_MATE/data"
# A 64-character id is legal (bin/fm-pr-lib.sh caps ids there), and its session
# name is shortened, so matching it proves the sweep derives names forward
# instead of stripping a prefix off one.
FLEET_LONG_ID="long-fleet-task-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
FLEET_LONG_SESSION=$(fm_browser_session_name "$FLEET_LONG_ID")
cat > "$FLEET_MAIN/data/backlog.md" <<'EOF'
# Backlog

## In flight
## Queued
## Done
EOF
cat > "$FLEET_MATE/data/backlog.md" <<EOF
# Backlog

## In flight
- [ ] other-home-task - a secondmate's worker, paused on an external wait (repo: alpha) (since 2026-08-01)
- [ ] $FLEET_LONG_ID - a secondmate's worker with a maximum-length id (repo: alpha) (since 2026-08-01)
## Queued
## Done
EOF
printf -- '- mate - owns alpha work (home: %s; scope: alpha; projects: alpha; added 2026-08-01)\n' \
  "$FLEET_MATE" > "$FLEET_MAIN/data/secondmates.md"

# A second fixture fleet whose registered secondmate home's backlog exists but
# cannot be read. The index still exits 0 for this - it reports the home as
# skipped and it simply contributes no open work - so this is the fleet that
# proves the sweep refuses an answer with a real gap in it instead of reading it
# as "that home has nothing open".
FLEET_PARTIAL_MAIN="$TMP_ROOT/fleet-partial-main"
FLEET_PARTIAL_MATE="$TMP_ROOT/fleet-partial-mate"
mkdir -p "$FLEET_PARTIAL_MAIN/data" "$FLEET_PARTIAL_MATE/data"
cat > "$FLEET_PARTIAL_MAIN/data/backlog.md" <<'EOF'
# Backlog

## In flight
## Queued
## Done
EOF
printf -- '- mate - owns alpha work (home: %s; scope: alpha; projects: alpha; added 2026-08-01)\n' \
  "$FLEET_PARTIAL_MATE" > "$FLEET_PARTIAL_MAIN/data/secondmates.md"
printf '# Backlog\n\n## In flight\n## Queued\n## Done\n' \
  > "$FLEET_PARTIAL_MATE/data/backlog.md"
chmod 000 "$FLEET_PARTIAL_MATE/data/backlog.md"
FLEET_PARTIAL_READABLE=1
# Running as a user who can read anything (root in a container) makes this
# fixture unbuildable rather than failing; the case says so instead of passing
# on a condition it never created.
[ -r "$FLEET_PARTIAL_MATE/data/backlog.md" ] && FLEET_PARTIAL_READABLE=0

# A third fixture fleet whose registered secondmate home has NO backlog file at
# all, which is what bin/fm-home-seed.sh leaves behind until work is filed in a
# home. The index reports it as skipped too, but nothing is missing: a home with
# no backlog has no open backlog rows. This is the ordinary steady state of a
# real fleet, so the sweep has to keep working normally against it.
FLEET_BENIGN_MAIN="$TMP_ROOT/fleet-benign-main"
FLEET_BENIGN_MATE="$TMP_ROOT/fleet-benign-mate"
mkdir -p "$FLEET_BENIGN_MAIN/data" "$FLEET_BENIGN_MATE/data"
cat > "$FLEET_BENIGN_MAIN/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] benign-open-task - this home's own open work (repo: alpha) (since 2026-08-01)
## Queued
## Done
EOF
printf -- '- mate - owns alpha work (home: %s; scope: alpha; projects: alpha; added 2026-08-01)\n' \
  "$FLEET_BENIGN_MATE" > "$FLEET_BENIGN_MAIN/data/secondmates.md"

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

# start_fake_cli <dir>: a running process whose command line carries the package
# name but is NOT the bridge - the shape a short-lived `chrome-devtools-axi
# <cmd>` invocation has. This is the nastiest reused-pid case, because the
# reported stop command SIGTERMs and then SIGKILLs the recorded pid whatever it
# turns out to be.
start_fake_cli() {
  local dir=$1 script="$1/chrome-devtools-axi.js" pid
  mkdir -p "$dir"
  cat > "$script" <<'SH'
#!/usr/bin/env bash
sleep 300
SH
  chmod +x "$script"
  "$script" >/dev/null 2>&1 &
  pid=$!
  HELD_PIDS+=("$pid")
  await_args "$pid" chrome-devtools-axi.js
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

# FM_HOME selects the fixture fleet the sweep consults for open work. Without it
# the real cross-home index would read the developer's own backlog, and one open
# item of theirs named like a fixture task would silently protect it.
run_sweep_in_home() {  # <home> <root> [args...]
  local home=$1 root=$2
  shift 2
  ( cd "$TMP_ROOT" && env -u FM_BROWSER_SWEEP_HOMES FM_HOME="$home" \
    "$SWEEP" --root "$root" "$@" ) 2>&1
}

run_sweep() {
  local root=$1
  shift
  run_sweep_in_home "$FLEET_MAIN" "$root" "$@"
}

# A bin/ holding the sweep and the libs it sources, plus whatever stands in for
# the cross-home work index. The sweep resolves the index next to itself, so
# this is how an index that cannot be consulted is presented to it.
#
# The payload modes are written against the fm-fleet-work-index.v1 object, which
# is that script's declared machine-readable interface, so what they encode is a
# contract the real index emits and not a guess at its internals.
sweep_bin_with_index() {  # <dir> <absent|fails|hangs|wrong-schema|partial-subtree>
  local dir=$1 mode=$2 bindir="$1/bin" index
  mkdir -p "$bindir"
  cp "$ROOT/bin/fm-browser-sweep.sh" "$ROOT/bin/fm-supervision-lib.sh" \
    "$ROOT/bin/fm-browser-session-lib.sh" "$bindir/"
  index="$bindir/fm-fleet-work-index.sh"
  case "$mode" in
    absent) : ;;
    fails)
      printf '%s\n' '#!/usr/bin/env bash' 'exit 3' > "$index"
      ;;
    hangs)
      printf '%s\n' '#!/usr/bin/env bash' 'sleep 120' > "$index"
      ;;
    wrong-schema)
      printf '%s\n' '#!/usr/bin/env bash' \
        'printf %s "{\"schema\":\"something-else.v1\",\"items\":[]}"' > "$index"
      ;;
    partial-subtree)
      # Every home was READ, so homes_skipped is 0 - but one home's secondmate
      # registry could not be enumerated, so that home's whole subtree is
      # missing from items[] and the run still succeeded.
      cat > "$index" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"schema":"fm-fleet-work-index.v1",
 "totals":{"homes":2,"homes_read":2,"homes_skipped":0,"items":1},
 "homes":[{"mate":"main","home":"/fixture/main","skipped":false,"reason":null,
           "subtree_reason":null,"work_unknown":false},
          {"mate":"mate","home":"/fixture/mate","skipped":false,"reason":null,
           "subtree_reason":"secondmate registry is unreadable, so this home's secondmates could not be enumerated",
           "work_unknown":true}],
 "skipped":[],
 "items":[{"mate":"main","home":"/fixture/main","id":"visible-task","state":"in_flight"}]}
JSON
SH
      ;;
    *) fail "unknown index fixture mode: $mode" ;;
  esac
  [ "$mode" = absent ] || chmod +x "$index"
  printf '%s\n' "$bindir/fm-browser-sweep.sh"
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

# Bridge state is host-global while a task lives in exactly one home, so the
# session an operator is told to stop can belong to a worker this home has never
# heard of. That worker is exactly the case the sweep must never report: a task
# deliberately parked on an external wait looks identical, from the outside, to
# an abandoned one.
test_open_work_in_another_home_is_never_reported() {
  local root owned_pid long_pid orphan_pid dir out
  root=$(new_root fleet-owned)
  owned_pid=$(start_fake_bridge "$root/proc")
  long_pid=$(start_fake_bridge "$root/proc")
  orphan_pid=$(start_fake_bridge "$root/proc")

  dir=$(write_session "$root" fm-other-home-task "$owned_pid")
  age_out "$dir/bridge.pid" "$dir/snapshot-generation"
  dir=$(write_session "$root" "$FLEET_LONG_SESSION" "$long_pid")
  age_out "$dir/bridge.pid" "$dir/snapshot-generation"
  dir=$(write_session "$root" fm-nobody-task "$orphan_pid")
  age_out "$dir/bridge.pid" "$dir/snapshot-generation"

  out=$(run_sweep "$root" --age-hours 12)
  assert_not_contains "$out" "fm-other-home-task" \
    "a bridge whose task is in flight in another home was reported as an orphan"
  assert_not_contains "$out" "$FLEET_LONG_SESSION" \
    "a bridge whose maximum-length task id is in flight in another home was reported as an orphan"
  assert_contains "$out" "fm-nobody-task: idle:" \
    "a bridge whose task is open nowhere in the fleet was not reported"
  pass "fm-browser-sweep: a session owned by open work in any home is left alone, whatever its id length, and one owned nowhere is still reported"
}

# The fleet's open work is a precondition for reporting, not an enhancement.
# With no way to read it, every session on the host is indistinguishable from a
# live worker's, and flagging one anyway is the exact harm this sweep exists to
# avoid - so it says so once, about the whole run, and flags nothing.
test_unconsultable_fleet_index_reports_nothing_idle() {
  local mode root pid dir sweep out
  for mode in absent fails wrong-schema; do
    root=$(new_root "no-index-$mode")
    sweep=$(sweep_bin_with_index "$root" "$mode")
    pid=$(start_fake_bridge "$root/proc")
    dir=$(write_session "$root" fm-nobody-task "$pid")
    age_out "$dir/bridge.pid" "$dir/snapshot-generation"

    out=$( cd "$TMP_ROOT" && env -u FM_BROWSER_SWEEP_HOMES FM_HOME="$FLEET_MAIN" \
      "$sweep" --root "$root" --age-hours 12 2>&1 )
    assert_contains "$out" "$root: skipped:" \
      "$mode: an unconsultable fleet index did not produce a whole-sweep skip"
    assert_not_contains "$out" "idle:" \
      "$mode: a session was reported idle with no way to check the fleet's open work"
    assert_not_contains "$out" "chrome-devtools-axi stop" \
      "$mode: a stop command was handed to the operator with no way to check the fleet's open work"
  done
  pass "fm-browser-sweep: an unreadable, failing, or unrecognized fleet work index skips the whole sweep instead of flagging a live worker's browser"
}

# The index answers successfully on a PARTIAL read: a home whose backlog it
# cannot read is reported as skipped and contributes no items. Reading that as
# "no open work owns this session" is how a live worker in that very home gets
# its browser stopped, so an incomplete answer has to be worth exactly as much
# as no answer - and it has to say which home went unread, or the operator has
# nothing to repair.
test_partially_read_fleet_index_reports_nothing_idle() {
  local root pid dir out
  [ "$FLEET_PARTIAL_READABLE" -eq 1 ] || {
    pass "fm-browser-sweep: unreadable-backlog fleet skipped, this user can read a mode-000 file"
    return 0
  }
  root=$(new_root partial-index)
  pid=$(start_fake_bridge "$root/proc")
  dir=$(write_session "$root" fm-nobody-task "$pid")
  age_out "$dir/bridge.pid" "$dir/snapshot-generation"

  # The same bridge against the complete fleet is reported, so the silence below
  # is the incompleteness being caught and not the fixture failing to look idle.
  out=$(run_sweep "$root" --age-hours 12)
  assert_contains "$out" "fm-nobody-task: idle:" \
    "the fixture bridge is not reported even against a fully readable fleet"

  out=$(run_sweep_in_home "$FLEET_PARTIAL_MAIN" "$root" --age-hours 12)
  assert_contains "$out" "$root: skipped:" \
    "a fleet index that could not read every home did not produce a whole-sweep skip"
  assert_contains "$out" "$FLEET_PARTIAL_MATE" \
    "the whole-sweep skip did not name the home that went unread"
  assert_not_contains "$out" "idle:" \
    "a session was reported idle while a home's open work was unreadable"
  pass "fm-browser-sweep: a fleet index that could not read a home's backlog skips the whole sweep and names that home"
}

# A skip is not by itself a gap. A seeded secondmate home carries no
# data/backlog.md until work is filed in it, so most real fleets are skipped
# homes in the steady state - and refusing on those would leave this sweep
# permanently unable to report the orphans it exists to surface, with the digest
# telling the operator to go repair perfectly healthy homes.
test_benign_index_skips_still_sweep_normally() {
  local root pid dir out
  root=$(new_root benign-index)
  pid=$(start_fake_bridge "$root/proc")
  dir=$(write_session "$root" fm-nobody-task "$pid")
  age_out "$dir/bridge.pid" "$dir/snapshot-generation"

  out=$(run_sweep_in_home "$FLEET_BENIGN_MAIN" "$root" --age-hours 12)
  assert_contains "$out" "fm-nobody-task: idle:" \
    "a fleet whose only skipped home simply has no backlog file went silent instead of reporting an orphan"
  assert_not_contains "$out" "skipped:" \
    "an ordinary backlog-less home was reported as a gap in the fleet's open work"
  pass "fm-browser-sweep: a fleet whose only skips are ordinary still reports an orphaned bridge"
}

# The same distinction seen from the other side: the benign fleet's own open
# work must still be read and still protect its session, so narrowing the
# refusal cannot have narrowed the protection with it.
test_benign_index_skips_still_protect_open_work() {
  local root pid dir out
  root=$(new_root benign-index-protects)
  pid=$(start_fake_bridge "$root/proc")
  dir=$(write_session "$root" fm-benign-open-task "$pid")
  age_out "$dir/bridge.pid" "$dir/snapshot-generation"

  out=$(run_sweep_in_home "$FLEET_BENIGN_MAIN" "$root" --age-hours 12)
  assert_not_contains "$out" "fm-benign-open-task" \
    "an in-flight task's session was reported once the fleet had an ordinary skipped home"
  pass "fm-browser-sweep: open work is still read and still protected in a fleet that has ordinary skipped homes"
}

# The other half of an incomplete answer: every home was read, but one home's
# secondmate registry could not be enumerated, so that home's entire subtree is
# absent from items[] while homes_skipped stays 0.
test_unenumerated_secondmate_subtree_reports_nothing_idle() {
  local root pid dir sweep out
  root=$(new_root partial-subtree)
  sweep=$(sweep_bin_with_index "$root" partial-subtree)
  pid=$(start_fake_bridge "$root/proc")
  dir=$(write_session "$root" fm-nobody-task "$pid")
  age_out "$dir/bridge.pid" "$dir/snapshot-generation"

  out=$( cd "$TMP_ROOT" && env -u FM_BROWSER_SWEEP_HOMES FM_HOME="$FLEET_MAIN" \
    "$sweep" --root "$root" --age-hours 12 2>&1 )
  assert_contains "$out" "$root: skipped:" \
    "an index hiding a whole secondmate subtree did not produce a whole-sweep skip"
  assert_contains "$out" "/fixture/mate" \
    "the whole-sweep skip did not name the home whose secondmates went unenumerated"
  assert_not_contains "$out" "idle:" \
    "a session was reported idle while a secondmate subtree's open work was invisible"
  pass "fm-browser-sweep: a fleet index that could not enumerate a home's secondmates skips the whole sweep rather than trusting the ids it did return"
}

# The index walks every registered home, so one on a hung mount would otherwise
# hold session start open indefinitely. An expiry is just another unavailable
# answer and takes the same fail-safe path.
test_slow_fleet_index_is_bounded_and_reports_nothing_idle() {
  local root pid dir sweep out started elapsed
  # The bound is deliberately optional, the same way teardown's browser stop is,
  # so a host without `timeout` runs unbounded rather than never sweeping.
  command -v timeout >/dev/null 2>&1 || {
    pass "fm-browser-sweep: bounded fleet index skipped, timeout not found"
    return 0
  }
  root=$(new_root slow-index)
  sweep=$(sweep_bin_with_index "$root" hangs)
  pid=$(start_fake_bridge "$root/proc")
  dir=$(write_session "$root" fm-nobody-task "$pid")
  age_out "$dir/bridge.pid" "$dir/snapshot-generation"

  started=$(date +%s)
  out=$( cd "$TMP_ROOT" && env -u FM_BROWSER_SWEEP_HOMES FM_HOME="$FLEET_MAIN" \
    FM_BROWSER_SWEEP_INDEX_TIMEOUT=1 "$sweep" --root "$root" --age-hours 12 2>&1 )
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 30 ] \
    || fail "the sweep waited ${elapsed}s on an index that never returns"
  assert_contains "$out" "$root: skipped:" \
    "an index that outlived its bound did not produce a whole-sweep skip"
  assert_not_contains "$out" "idle:" \
    "a session was reported idle after the fleet index timed out"
  pass "fm-browser-sweep: an index that never returns is bounded, and its expiry reports nothing idle"
}

test_dead_and_reused_pids_are_not_reported() {
  local root dead_pid other_pid cli_pid live_pid dir out
  root=$(new_root pid-identity)

  dead_pid=$(start_fake_bridge "$root/proc")
  kill "$dead_pid" 2>/dev/null || true
  wait "$dead_pid" 2>/dev/null || true
  dir=$(write_session "$root" fm-dead-task "$dead_pid")
  age_out "$dir/bridge.pid" "$dir/snapshot-generation"

  other_pid=$(start_fake_other "$root/proc")
  dir=$(write_session "$root" fm-reused-task "$other_pid")
  age_out "$dir/bridge.pid" "$dir/snapshot-generation"

  cli_pid=$(start_fake_cli "$root/proc")
  dir=$(write_session "$root" fm-cli-task "$cli_pid")
  age_out "$dir/bridge.pid" "$dir/snapshot-generation"

  # A real bridge in the same run, so the absences above are the identity check
  # working rather than the whole sweep having gone quiet.
  live_pid=$(start_fake_bridge "$root/proc")
  dir=$(write_session "$root" fm-real-task "$live_pid")
  age_out "$dir/bridge.pid" "$dir/snapshot-generation"

  out=$(run_sweep "$root" --age-hours 12)
  assert_not_contains "$out" "fm-dead-task" \
    "a bridge record whose process is gone was reported as a live orphan"
  assert_not_contains "$out" "fm-reused-task" \
    "a pid the OS reused for an unrelated process was reported as a bridge"
  assert_not_contains "$out" "fm-cli-task" \
    "a pid the OS reused for a chrome-devtools-axi CLI call was reported as a bridge"
  assert_contains "$out" "fm-real-task: idle:" \
    "the identity check silenced a genuine idle bridge too"
  kill -0 "$cli_pid" 2>/dev/null \
    || fail "the sweep killed the unrelated chrome-devtools-axi process"
  pass "fm-browser-sweep: a released pid, a pid reused by an unrelated process, and a pid reused by a chrome-devtools-axi CLI call are all left alone"
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
test_open_work_in_another_home_is_never_reported
test_unconsultable_fleet_index_reports_nothing_idle
test_partially_read_fleet_index_reports_nothing_idle
test_benign_index_skips_still_sweep_normally
test_benign_index_skips_still_protect_open_work
test_unenumerated_secondmate_subtree_reports_nothing_idle
test_slow_fleet_index_is_bounded_and_reports_nothing_idle
test_dead_and_reused_pids_are_not_reported
test_default_session_is_examined_without_borrowing_named_activity
test_unreadable_record_is_reported_and_missing_root_is_silent
test_sweep_never_stops_a_session
