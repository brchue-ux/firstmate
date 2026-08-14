#!/usr/bin/env bash
# fm-idle-sweep.sh - reclaim finished tasks in this home that are still holding
# a runtime endpoint or a worktree.
#
# Why this exists: nothing ever reclaimed an ordinary finished task. Cleanup was
# entirely manual - bin/fm-teardown.sh ran only when firstmate was explicitly
# told to run it - so a task that reported `done:` or `failed:` kept its pane
# and its worktree indefinitely, and the captain saw finished workers sitting in
# the sidebar with no explanation until someone asked why. Neither Herdr cleanup
# script covers this: bin/fm-herdr-session-cleanup.sh retires remnants of the
# opt-in presentation projection, and bin/fm-herdr-ci-cleanup.sh retires
# isolated fm-lab-* CI sessions. Neither touches an ordinary task pane.
#
# This is that sweep. bin/fm-watch.sh runs it on the heartbeat cadence, so it is
# part of every heartbeat's fleet reconciliation (AGENTS.md section 8). Every
# home runs its own watcher, so the primary home and each secondmate home sweep
# themselves and no home ever reaches into another home's tasks.
#
# SAFETY BOUNDARY: this script decides only WHICH tasks to offer to
# bin/fm-teardown.sh. It never decides whether tearing one down is safe.
# fm-teardown.sh owns the complete landed-work test and refuses uncommitted
# changes, commits reachable from no remote, and an unmerged PR (AGENTS.md hard
# rule 3). The sweep never passes --force and never inspects or second-guesses
# that verdict, so a task that reported `done:` while its PR is still landing is
# simply refused and left exactly as it was - the same outcome as before this
# sweep existed. Attempting cleanup automatically is safe precisely because that
# refusal already exists; the sweep exists to make the attempt, not the ruling.
#
# CONCURRENCY, AND EXACTLY WHAT IT DOES NOT COVER: because the watcher now starts
# this sweep on a cadence rather than a human starting it, two of them can be in
# flight at once - a slow one still running when the next heartbeat arrives, or a
# hand-run one alongside the watcher's. A single sweep-wide lock
# (state/.idle-sweep.lock, the same lock primitive and dead-holder handling the
# watcher singleton and fm-spawn.sh use) makes that impossible: a run that finds
# it held exits 0 in silence, since a sweep already running is not an error and
# the watcher must never be made noisy or blocked by one. --dry-run is exempt
# from that lock, because it changes nothing at all - no teardown, no backoff
# record, not even the orphan-marker cleanup below - so an operator can always
# get an answer out of it, including while the watcher's sweep is mid-flight.
# That lock closes sweep-versus-sweep ONLY. It does NOT make this sweep exclusive
# with a captain- or firstmate-initiated `fm-teardown.sh <id>` for the same task:
# the two can still run at once, and if they do they can both pass teardown's
# safety checks and both start reclaiming the same records. Closing that would
# take a per-task lock inside fm-teardown.sh, which is deliberately out of scope
# here. Neither can discard unlanded work - each runs teardown's full refusal -
# so the exposure is a confusing half-torn-down task and duplicate output, not
# lost work.
#
# Usage:
#   fm-idle-sweep.sh [--dry-run] [--verbose] [--budget-secs <n>]
#                    [--task-timeout-secs <n>] [--retry-secs <n>]
#   fm-idle-sweep.sh -h | --help
#
# A task is offered to teardown only when all of these hold, cheapest first:
#   - state/<id>.meta exists and <id> is a path-safe task id
#   - its kind is not secondmate. A secondmate is persistent by design and is
#     retired only on an explicit captain or main-firstmate decision
#     (AGENTS.md section 7), never by a periodic sweep
#   - the last line of state/<id>.status carries the done: or failed: verb
#   - it still holds something to reclaim: the recorded worktree still exists as
#     a directory, or the recorded runtime endpoint is not confidently dead. A
#     task holding neither is left to the recovery path that owns a lost
#     endpoint, not silently cleaned up here
#   - bin/fm-crew-state.sh does not reconcile the crew to `working` or `parked`.
#     A status line is a wake event, not current-state truth (AGENTS.md section
#     8), so a crew that resumed after its `done:` line, or is parked at a gate
#     waiting on a decision, is never offered for cleanup on the strength of a
#     stale log line
#   - its retry window is open (below)
#
# Backoff: each attempt writes state/.idle-sweep-<id>, holding a signature of
# the inputs that decided it and the time it was attempted. A task whose
# teardown refused is retried when that signature changes (its status log or
# metadata moved, so there is new evidence) or once --retry-secs has passed,
# whichever comes first. That keeps a task that is genuinely still landing from
# re-running a network-touching teardown on every heartbeat, without building a
# scheduler for it. The record is written BEFORE the attempt, so a sweep killed
# mid-teardown backs off rather than retrying immediately on the next tick.
#
# Bounding: the whole sweep stops offering new tasks once --budget-secs elapses,
# and each teardown is capped at --task-timeout-secs when `timeout` is
# available. Both defaults sit well inside the watcher's liveness grace
# (FM_WATCHER_STALE_GRACE, default 300s) so a slow sweep can never make a live
# watcher look wedged to bin/fm-guard.sh. A teardown that hits the cap is treated
# as a refusal: the task keeps all its records, backs off, and is retried later or
# cleaned up by hand, which is the pre-sweep behavior anyway. Interrupting one
# mid-git is the same exposure as a crew process killed mid-operation, which
# fm-teardown.sh's stale-worktree-lock recovery already handles.
#
# Output is one line per notable outcome in the "<subject>: <verb>: <detail>"
# shape the other sweeps use, and silent otherwise:
#   "<id>: cleaned up"
#   "<id>: refused: <detail>"    - teardown declined; --verbose only
#   "<id>: skipped: <reason>"    - not eligible this tick; --verbose only
#   "<id>: would clean up"       - --dry-run
#   "sweep: skipped: time budget exhausted after <n>s"
#
# Exit status:
#   0  the sweep ran; individual tasks may have been skipped or refused, or
#      another sweep in this home already held the sweep-wide lock (--dry-run
#      never stands down that way)
#   1  the arguments were invalid
#   3  refused because this process looks like a no-mistakes gate agent
#      (bin/fm-gate-refuse-lib.sh)
#
# Test seams, in the same spirit as fm-classify-lib.sh's FM_CREW_STATE_BIN:
# FM_IDLE_SWEEP_TEARDOWN_BIN replaces the teardown entrypoint and
# FM_CREW_STATE_BIN replaces the current-state reader, so the sweep's selection
# behavior can be exercised without a real fleet.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# FM_HOME resolution: see bin/fm-home-anchor-lib.sh:1-22 ("Why this exists").
# shellcheck source=bin/fm-home-anchor-lib.sh
. "$SCRIPT_DIR/fm-home-anchor-lib.sh"
fm_home_anchor_resolve "$FM_ROOT" || exit 1
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Single-flight lock primitives (and their dead-holder recovery) have one owner:
# bin/fm-wake-lib.sh, the same one the watcher singleton claims through.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-idle-sweep.sh [--dry-run] [--verbose] [--budget-secs <n>]
                        [--task-timeout-secs <n>] [--retry-secs <n>]

Attempt bin/fm-teardown.sh for every task in this home whose last recorded
status is done: or failed: and that still holds a worktree or runtime endpoint.
Teardown owns the landed-work refusal; this sweep never passes --force, so a
task whose work has not landed is left untouched.

  --dry-run              report what would be attempted; change nothing
  --verbose              also report skips and teardown refusals
  --budget-secs <n>      stop offering new tasks after n seconds (0 = no limit)
  --task-timeout-secs <n>  cap each teardown at n seconds (0 = no cap)
  --retry-secs <n>       retry a refused task after n seconds even if nothing
                         about it changed
  -h, --help             show this help
EOF
}

DRY_RUN=0
VERBOSE=0
BUDGET_SECS=${FM_IDLE_SWEEP_BUDGET_SECS:-120}
TASK_TIMEOUT_SECS=${FM_IDLE_SWEEP_TASK_TIMEOUT_SECS:-60}
RETRY_SECS=${FM_IDLE_SWEEP_RETRY_SECS:-3600}
TEARDOWN_BIN=${FM_IDLE_SWEEP_TEARDOWN_BIN:-$SCRIPT_DIR/fm-teardown.sh}

require_count() {  # <value> <flag>
  case "$1" in
    ''|*[!0-9]*) echo "fm-idle-sweep.sh: $2 needs a non-negative integer" >&2; exit 1 ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --verbose) VERBOSE=1 ;;
    --budget-secs) shift; BUDGET_SECS=${1:-}; require_count "$BUDGET_SECS" --budget-secs ;;
    --task-timeout-secs) shift; TASK_TIMEOUT_SECS=${1:-}; require_count "$TASK_TIMEOUT_SECS" --task-timeout-secs ;;
    --retry-secs) shift; RETRY_SECS=${1:-}; require_count "$RETRY_SECS" --retry-secs ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fm-idle-sweep.sh: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done
require_count "$BUDGET_SECS" --budget-secs
require_count "$TASK_TIMEOUT_SECS" --task-timeout-secs
require_count "$RETRY_SECS" --retry-secs

# Fail closed before any fleet mutation: a no-mistakes gate agent must never
# drive cleanup (see bin/fm-gate-refuse-lib.sh). fm-teardown.sh refuses on its
# own too; refusing here as well keeps the whole entrypoint out of that context
# instead of surfacing a run of confusing per-task failures.
fm_refuse_if_gate_agent

# Scratch for one teardown's combined output; created once the sweep reaches the
# loop, and removed alongside the lock on every exit path.
ATTEMPT_OUT=
SWEEP_LOCK="$STATE/.idle-sweep.lock"
SWEEP_LOCK_HELD=0
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
sweep_cleanup() {
  [ -z "$ATTEMPT_OUT" ] || rm -f "$ATTEMPT_OUT"
  if [ "$SWEEP_LOCK_HELD" -eq 1 ]; then
    SWEEP_LOCK_HELD=0
    fm_lock_release "$SWEEP_LOCK" || true
  fi
  return 0
}
trap sweep_cleanup EXIT
trap 'exit 1' HUP INT TERM

# Single-flight across this home's sweeps only; see CONCURRENCY in the header for
# what that does and does not cover. Finding the lock held is the ordinary quiet
# case - a sweep is already doing this work - so say nothing and succeed, because
# the watcher calls this every heartbeat and must never be made noisy by it.
# --dry-run has nothing to exclude, so it never takes the lock and stays
# answerable while a real sweep runs.
if [ "$DRY_RUN" -eq 0 ]; then
  fm_lock_try_acquire "$SWEEP_LOCK" || exit 0
  SWEEP_LOCK_HELD=1
fi

TIMEOUT_CMD=
command -v timeout >/dev/null 2>&1 && TIMEOUT_CMD=timeout

# Portable mtime/size signature. Platform-detected once, never the
# `stat -f ... || stat -c ...` fallback form, which writes a partial filesystem
# dump on Linux before failing (see bin/fm-watch.sh's stat notes).
if [ "$(uname)" = Darwin ]; then
  path_sig() { stat -f '%z:%Fm' "$1" 2>/dev/null || true; }
else
  path_sig() { stat -c '%s:%Y' "$1" 2>/dev/null || true; }
fi

STARTED=$(date +%s)

budget_open() {
  [ "$BUDGET_SECS" -eq 0 ] && return 0
  [ "$(( $(date +%s) - STARTED ))" -lt "$BUDGET_SECS" ]
}

report() { printf '%s\n' "$1"; }
report_verbose() { [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$1"; return 0; }

marker_path() { printf '%s/.idle-sweep-%s' "$STATE" "$1"; }

# The evidence this tick's decision rests on. When it changes there is something
# new to act on, so a previously refused task becomes eligible again immediately
# instead of waiting out the retry window.
task_signature() {  # <id>
  printf '%s|%s' "$(path_sig "$STATE/$1.status")" "$(path_sig "$STATE/$1.meta")"
}

# 0 when <id> may be attempted this tick.
retry_window_open() {  # <id> <signature>
  local sig=$2 marker prev_sig prev_at
  marker=$(marker_path "$1")
  [ -f "$marker" ] || return 0
  prev_sig=$(sed -n 1p "$marker" 2>/dev/null || true)
  prev_at=$(sed -n 2p "$marker" 2>/dev/null || true)
  [ "$prev_sig" = "$sig" ] || return 0
  case "$prev_at" in ''|*[!0-9]*) return 0 ;; esac
  [ "$(( $(date +%s) - prev_at ))" -ge "$RETRY_SECS" ]
}

record_attempt() {  # <id> <signature>
  local marker
  marker=$(marker_path "$1")
  printf '%s\n%s\n' "$2" "$(date +%s)" > "$marker" 2>/dev/null || true
}

# The crew's reconciled current state word, or `unknown` when it cannot be read.
# Same parse as fm-classify-lib.sh's crew_absorb_class, against the same reader.
crew_current_state() {  # <id>
  local line
  line=$("$FM_CREW_STATE_BIN" "$1" 2>/dev/null) || true
  case "$line" in state:*) ;; *) printf 'unknown'; return 0 ;; esac
  line=${line#state: }
  printf '%s' "${line%% *}"
}

# 0 when the task still has a runtime endpoint or worktree worth reclaiming.
task_holds_resources() {  # <meta>
  local meta=$1 wt backend target
  wt=$(fm_meta_get "$meta" worktree)
  [ -n "$wt" ] && [ -d "$wt" ] && return 0
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || return 1
  backend=$(fm_backend_of_meta "$meta")
  # `unknown` counts as holding: an endpoint we cannot confidently call dead is
  # one teardown should still be offered, and teardown itself is the safe judge.
  [ "$(fm_backend_agent_alive "$backend" "$target")" != dead ]
}

# One bounded line describing why teardown declined, preferring its own REFUSED
# line over trailing noise.
refusal_detail() {  # <output-file>
  local line
  line=$(grep -m1 'REFUSED' "$1" 2>/dev/null || true)
  [ -n "$line" ] || line=$(grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -1 || true)
  [ -n "$line" ] || line='no detail reported'
  printf '%.300s' "$line"
}

run_teardown() {  # <id> <output-file>
  if [ -n "$TIMEOUT_CMD" ] && [ "$TASK_TIMEOUT_SECS" -gt 0 ]; then
    "$TIMEOUT_CMD" "$TASK_TIMEOUT_SECS" "$TEARDOWN_BIN" "$1" > "$2" 2>&1
  else
    "$TEARDOWN_BIN" "$1" > "$2" 2>&1
  fi
}

ATTEMPT_OUT=$(mktemp "${TMPDIR:-/tmp}/fm-idle-sweep.XXXXXX") || {
  ATTEMPT_OUT=
  echo "fm-idle-sweep.sh: cannot create scratch file" >&2
  exit 1
}

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  id=$(basename "$meta" .meta)
  if ! fm_task_id_path_safe "$id"; then
    report_verbose "$id: skipped: unsafe task id"
    continue
  fi
  if ! budget_open; then
    report "sweep: skipped: time budget exhausted after ${BUDGET_SECS}s"
    break
  fi

  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" = secondmate ]; then
    report_verbose "$id: skipped: secondmates are retired by explicit decision, not swept"
    continue
  fi

  verb=$(status_line_verb "$(last_status_line "$STATE/$id.status")")
  case "$verb" in
    done|failed) ;;
    *)
      report_verbose "$id: skipped: last recorded status is not done or failed"
      continue ;;
  esac

  if ! task_holds_resources "$meta"; then
    report_verbose "$id: skipped: no worktree or live endpoint left to reclaim"
    continue
  fi

  state_now=$(crew_current_state "$id")
  case "$state_now" in
    working|parked)
      report_verbose "$id: skipped: currently $state_now, not finished"
      continue ;;
  esac

  sig=$(task_signature "$id")
  if ! retry_window_open "$id" "$sig"; then
    report_verbose "$id: skipped: waiting out the retry window since the last refusal"
    continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    report "$id: would clean up"
    continue
  fi

  # Recorded before the attempt so a sweep killed mid-teardown backs off instead
  # of retrying immediately on the next heartbeat.
  record_attempt "$id" "$sig"
  if run_teardown "$id" "$ATTEMPT_OUT"; then
    rm -f "$(marker_path "$id")"
    report "$id: cleaned up"
  else
    report_verbose "$id: refused: $(refusal_detail "$ATTEMPT_OUT")"
  fi
  : > "$ATTEMPT_OUT"
done

# Drop backoff records for tasks that are gone, so a home that has run for months
# does not accumulate one dead marker per task ever swept or torn down by hand.
# Skipped under --dry-run, which reports and changes nothing.
if [ "$DRY_RUN" -eq 0 ]; then
  for marker in "$STATE"/.idle-sweep-*; do
    [ -f "$marker" ] || continue
    marker_id=$(basename "$marker")
    marker_id=${marker_id#.idle-sweep-}
    [ -e "$STATE/$marker_id.meta" ] || rm -f "$marker"
  done
fi

exit 0
