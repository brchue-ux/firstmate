#!/usr/bin/env bash
# fm-browser-sweep.sh - report chrome-devtools-axi browser bridges that no task
# is using any more. It never stops one.
#
# Why this exists: the chrome-devtools-axi bridge calls setsid() at startup, so
# it is its own session leader with no controlling terminal and is in neither the
# crewmate pane's process group nor its session. Closing the pane, returning the
# worktree, and removing the worktree's files all miss it, and it keeps a
# headless Chrome tree alive behind it - measured at 38 processes, 2.28 GB
# resident and 477 MB swap on one host before anything reaped them.
# bin/fm-teardown.sh closes the common case by stopping the task's own pinned
# session (bin/fm-brief.sh pins it to fm-<task id>), but a crewmate that was
# killed, crashed, or never reached teardown leaves its bridge behind, and a
# detached daemon can only ever be recovered out of band. This sweep is that
# out-of-band half.
#
# It only REPORTS. A bridge is indistinguishable, from the outside, from one a
# live worker is about to use again, and killing a working session mid-task is
# worse than leaving an idle daemon paged out. Whether to stop a flagged session
# is a firstmate or captain decision at the time, so each line carries the exact
# session-scoped stop command instead of running it.
#
# Usage:
#   fm-browser-sweep.sh [--age-hours <n> | --age-minutes <n>] [--root <dir>]
#                       [--protect-home <dir>]... [--verbose]
#   fm-browser-sweep.sh -h | --help
#
# A session is reported only when every one of these holds:
#   - chrome-devtools-axi records a bridge for it: bridge.pid in the session's
#     own state directory (sessions/<name>/ for a named session, the state root
#     itself for the legacy "default" session)
#   - that recorded pid is alive AND still belongs to a chrome-devtools-axi
#     BRIDGE process. A pid the OS has reused for something else is not this
#     tool's - and neither is a short-lived `chrome-devtools-axi <cmd>` CLI call,
#     whose argv also carries the package name - so the match is the bridge
#     entry point specifically. Reporting either would send an operator to kill
#     an unrelated process
#   - no --protect-home records it as a live task's session. A session pinned to
#     a task whose state/<task id>.meta still exists belongs to work in flight -
#     including a task deliberately idling on an external wait - and a long-idle
#     browser is normal there
#   - nothing in the session's own state has been written within the age window
#   - no open work item anywhere in the fleet owns the session. Bridge state is
#     host-global, so a session can belong to a live worker in a secondmate home
#     this sweep knows nothing about; bin/fm-fleet-work-index.sh already answers
#     "what is open anywhere", transitively and read-only, so it is consulted
#     once per run and every open item's pinned session name is protected.
#     Session names are derived FROM ids through bin/fm-browser-session-lib.sh,
#     never parsed back out of a name: a shortened name has no id to recover.
#     The index must have determined EVERY home's open work to answer this. It
#     succeeds on a partial read by design - a backlog it cannot read or parse,
#     a home it cannot resolve, and a registry it cannot enumerate all leave
#     items[] short while the run still exits 0 - so a gap is treated exactly as
#     no answer, not as "that home has no open work". Which homes are a gap is
#     the index's own call, read from its per-home work_unknown; an ordinary
#     skip such as a home with no backlog file at all, or a home already counted
#     under an earlier registry id, is a complete answer and sweeps normally
# Idle is measured from that state, not from process age: a bridge started two
# days ago and used a minute ago is in use, and reporting it as an orphan is the
# error that gets a live session killed.
#
# The fleet index is a precondition for reporting, not a bonus. When it cannot
# be consulted - no jq, no index script, a non-zero exit, a run that outlived
# its time bound, output that is not an fm-fleet-work-index.v1 object, or a run
# that left any home's open work undetermined - this reports a whole-sweep skip
# naming the reason and those homes, and flags nothing, exactly as it does when
# ps is unusable. Falling back to flagging would trade a silent run for the one
# outcome this sweep exists to avoid: an operator stopping a live worker's
# browser. A home is never allowed to leave the answer silently, which is the
# same property bin/fm-fleet-work-index.sh maintains on its own side.
#
# Scope limit, narrowed but not gone: the index knows a task by its backlog row,
# so a session pinned to work that another home tracks only in state/<id>.meta,
# with no open row anywhere, is still reported. The lines are advisory, and the
# operator confirms ownership before stopping anything.
#
# Output is one line per notable outcome and silent otherwise, in the same
# "<subject>: <verb>: <detail>" shape the other session-start sweeps use:
#   "<session>: idle: <detail>"    - a bridge nothing has used for the window,
#                                    with the session-scoped stop command
#   "<session>: skipped: <reason>" - a bridge record that could not be read, so
#                                    idleness could not be decided either way
#   "<root>: skipped: <reason>"    - a whole-sweep limit (running processes could
#                                    not be identified at all, or the fleet's
#                                    open work could not be consulted), after
#                                    which nothing is reported idle in that run
# Healthy skips - in use, live task's, no bridge, dead record - stay silent
# unless --verbose is passed.
#
# Exit status:
#   0  the sweep ran
#   1  the arguments were invalid
#
# Environment overrides (defaults are the operating contract; these exist for
# tests and one-off manual runs, not as a configuration surface):
#   FM_BROWSER_SWEEP_AGE_HOURS    idle window in hours (default 12)
#   FM_BROWSER_SWEEP_AGE_MINUTES  idle window in minutes; wins over the hours form
#   FM_BROWSER_SWEEP_ROOT         chrome-devtools-axi state root
#                                 (default $HOME/.chrome-devtools-axi)
#   FM_BROWSER_SWEEP_HOMES        firstmate homes whose live tasks are protected,
#                                 colon-separated
#   FM_BROWSER_SWEEP_INDEX_TIMEOUT
#                                 seconds the cross-home work index may take
#                                 before its answer is treated as unavailable
#                                 (default 20; 0 disables the bound)
#
# The fleet index resolves its own home the ordinary way, from the environment
# this sweep was invoked with, so it settles on exactly the home its caller
# already settled on rather than being handed a laundered one.
set -u

SELF="${BASH_SOURCE[0]}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF" >&2
}

die() {
  printf 'fm-browser-sweep.sh: %s\n' "$1" >&2
  exit 1
}

AGE_HOURS=${FM_BROWSER_SWEEP_AGE_HOURS:-12}
AGE_MINUTES_OPT=${FM_BROWSER_SWEEP_AGE_MINUTES:-}
ROOT_DIR=${FM_BROWSER_SWEEP_ROOT:-${HOME:-}/.chrome-devtools-axi}
PROTECT_HOMES=${FM_BROWSER_SWEEP_HOMES:-}
FLEET_INDEX_TIMEOUT=${FM_BROWSER_SWEEP_INDEX_TIMEOUT:-20}
VERBOSE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --age-hours) [ $# -ge 2 ] || die "--age-hours needs a value"; AGE_HOURS=$2; AGE_MINUTES_OPT=; shift 2 ;;
    --age-minutes) [ $# -ge 2 ] || die "--age-minutes needs a value"; AGE_MINUTES_OPT=$2; shift 2 ;;
    --root) [ $# -ge 2 ] || die "--root needs a value"; ROOT_DIR=$2; shift 2 ;;
    --protect-home)
      [ $# -ge 2 ] || die "--protect-home needs a value"
      PROTECT_HOMES="${PROTECT_HOMES:+$PROTECT_HOMES:}$2"
      shift 2
      ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [ -n "$AGE_MINUTES_OPT" ]; then
  case "$AGE_MINUTES_OPT" in
    ''|*[!0-9]*) die "--age-minutes must be a whole number of minutes" ;;
  esac
  AGE_SECONDS=$((AGE_MINUTES_OPT * 60))
  AGE_WINDOW="${AGE_MINUTES_OPT}m"
else
  case "$AGE_HOURS" in
    ''|*[!0-9]*) die "--age-hours must be a whole number of hours" ;;
  esac
  AGE_SECONDS=$((AGE_HOURS * 3600))
  AGE_WINDOW="${AGE_HOURS}h"
fi

case "$FLEET_INDEX_TIMEOUT" in
  ''|*[!0-9]*) die "FM_BROWSER_SWEEP_INDEX_TIMEOUT must be a whole number of seconds" ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"

# Portable mtime has one owner in this repo; a second copy would drift.
# shellcheck source=bin/fm-supervision-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# The task-id-to-session-name derivation has one owner too: bin/fm-brief.sh
# writes the name, bin/fm-teardown.sh stops it, and this derives it back for
# every open task in the fleet. A second copy would drift into names that never
# match, which here means reporting a live worker's browser.
# shellcheck source=bin/fm-browser-session-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-browser-session-lib.sh"

FLEET_INDEX_CMD="$SCRIPT_DIR/fm-fleet-work-index.sh"

report() {
  printf '%s\n' "$1"
}

note() {
  [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$1"
  return 0
}

# Whether ps can report on a running process at all. Without it a live bridge
# cannot be told apart from a pid the OS has since reused, and every line this
# sweep prints is an invitation to kill something - so the whole sweep says so
# and reports nothing instead of guessing.
PS_USABLE=1
if [ -z "$(ps -o args= -p $$ 2>/dev/null)" ]; then
  PS_USABLE=0
fi

# Every open work item in the fleet, as the session name it would have pinned.
#
# Consulted at most once per run, and lazily: the sweep's normal outcome is
# silence, and reading every home's backlog is far more work than deciding that
# nothing has been idle long enough to report. Once it has been decided, it is
# not decided again - a per-session lookup would walk the fleet once per session
# directory, and this host has had 84 of those.
FLEET_INDEX_STATE=unread
FLEET_INDEX_REASON=
FLEET_TASK_SESSIONS=

# The index walks every registered home, so one on a stale or hung mount would
# otherwise hold session start open forever. The bound is the same reasoning
# bin/fm-teardown.sh applies to the browser stop and bin/fm-bootstrap.sh to
# fleet sync, and an expiry needs no path of its own: it is simply another way
# the answer is unavailable. `timeout` stays optional, exactly as it is on the
# teardown stop, so a host without it runs unbounded rather than never sweeping.
run_fleet_index() {
  if [ "$FLEET_INDEX_TIMEOUT" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
    timeout "$FLEET_INDEX_TIMEOUT" "$FLEET_INDEX_CMD" --json 2>/dev/null </dev/null
  else
    "$FLEET_INDEX_CMD" --json 2>/dev/null </dev/null
  fi
}

# Populate FLEET_TASK_SESSIONS, or set FLEET_INDEX_REASON and fail. Every
# failure mode here means "the fleet's open work is unknown", never "there is
# none": the caller must not report anything after one.
load_fleet_task_sessions() {
  local json ids id name rc unread
  command -v jq >/dev/null 2>&1 || {
    FLEET_INDEX_REASON="jq is not installed, so the fleet's open work could not be read"
    return 1
  }
  [ -x "$FLEET_INDEX_CMD" ] || {
    FLEET_INDEX_REASON="the cross-home work index is missing or not executable ($FLEET_INDEX_CMD)"
    return 1
  }
  json=$(run_fleet_index) || {
    rc=$?
    if [ "$rc" -eq 124 ]; then
      FLEET_INDEX_REASON="the cross-home work index did not finish within ${FLEET_INDEX_TIMEOUT}s"
    else
      FLEET_INDEX_REASON="the cross-home work index failed ($FLEET_INDEX_CMD --json)"
    fi
    return 1
  }

  # A home whose open work the index could not determine contributes no items
  # while the run still succeeds, which turns "no open work owns this session"
  # into "no open work we happened to see owns this session" - the assumption
  # that gets a live worker's browser stopped. So an answer with a genuine gap
  # in it is refused here and the homes are named, rather than mined for the ids
  # it does carry.
  #
  # The index answers this itself, per home, with work_unknown. A skip on its
  # own is not a gap and must not be read as one: a home with no backlog file at
  # all has no open backlog rows, and a home reached twice through the registry
  # graph is already counted under its first visit. Both are the ordinary
  # steady state of a real fleet, and refusing on them would leave this sweep
  # permanently unable to report anything. Anything absent or non-boolean counts
  # as unknown, so an index that does not answer the question cannot pass for
  # one that answered "complete".
  unread=$(printf '%s' "$json" | jq -r '
    if (.schema? == "fm-fleet-work-index.v1") and ((.items | type) == "array")
       and ((.homes | type) == "array")
    then
      ([ .homes[]
         | select(.work_unknown != false)
         | ((.home // .mate // "unnamed home") | tostring) + ": "
           + ((.reason // .subtree_reason // "open work could not be determined")
              | tostring) ]) as $problems
      | if ($problems | length) == 0 then ""
        else ($problems[0:3] | join("; "))
             + (if ($problems | length) > 3
                then "; and \(($problems | length) - 3) more" else "" end)
        end
    else error("not an fm-fleet-work-index.v1 object") end' 2>/dev/null) || {
    FLEET_INDEX_REASON="the cross-home work index did not emit a readable fm-fleet-work-index.v1 object"
    return 1
  }
  if [ -n "$unread" ]; then
    FLEET_INDEX_REASON="the fleet's open work could not be determined for every home ($unread)"
    return 1
  fi

  ids=$(printf '%s' "$json" | jq -r '.items[] | .id // empty' 2>/dev/null) || {
    FLEET_INDEX_REASON="the cross-home work index did not emit a readable fm-fleet-work-index.v1 object"
    return 1
  }
  FLEET_TASK_SESSIONS=" "
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    name=$(fm_browser_session_name "$id") || continue
    FLEET_TASK_SESSIONS="$FLEET_TASK_SESSIONS$name "
  done <<<"$ids"
  return 0
}

fleet_index_usable() {
  case "$FLEET_INDEX_STATE" in
    ready) return 0 ;;
    unusable) return 1 ;;
  esac
  if load_fleet_task_sessions; then
    FLEET_INDEX_STATE=ready
    return 0
  fi
  FLEET_INDEX_STATE=unusable
  report "$ROOT_DIR: skipped: $FLEET_INDEX_REASON, so a bridge a live task elsewhere in the fleet still owns cannot be told from an orphan"
  return 1
}

fleet_task_session() {
  case "$FLEET_TASK_SESSIONS" in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# A session pinned to a task a --protect-home still records is live work's,
# however long its browser has sat untouched: state/<task id>.meta exists
# exactly as long as the task does. This is the second layer under the fleet
# index, not a duplicate of it - a task can hold a meta with no backlog row at
# all (a scout dispatched straight from a conversation), and that is still work
# in flight.
#
# The direction is id -> name, never name -> id. A shortened session name
# (bin/fm-browser-session-lib.sh) carries a hash where the rest of the id was,
# so no id can be recovered from it; deriving the name each recorded task would
# have used is the only comparison that holds for every id length.
PROTECTED_SESSIONS=
PROTECTED_SESSIONS_LOADED=0

load_protected_sessions() {
  local rest=$PROTECT_HOMES home meta id name
  PROTECTED_SESSIONS=" "
  while [ -n "$rest" ]; do
    home=${rest%%:*}
    case "$rest" in
      *:*) rest=${rest#*:} ;;
      *) rest= ;;
    esac
    [ -n "$home" ] || continue
    [ -d "$home/state" ] || continue
    for meta in "$home"/state/*.meta; do
      [ -f "$meta" ] || continue
      id=${meta##*/}
      id=${id%.meta}
      name=$(fm_browser_session_name "$id") || continue
      PROTECTED_SESSIONS="$PROTECTED_SESSIONS$name "
    done
  done
}

protected_session() {
  if [ "$PROTECTED_SESSIONS_LOADED" -eq 0 ]; then
    load_protected_sessions
    PROTECTED_SESSIONS_LOADED=1
  fi
  case "$PROTECTED_SESSIONS" in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# Newest mtime among a session's own state files. Directories are skipped: the
# state root's own mtime changes when an unrelated named session is created, and
# that is not activity by this session.
newest_state_mtime() {
  local dir=$1 entry mtime newest=
  for entry in "$dir"/*; do
    [ -f "$entry" ] || continue
    mtime=$(fm_sup_stat_mtime "$entry") || continue
    case "$mtime" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ -z "$newest" ] || [ "$mtime" -gt "$newest" ]; then
      newest=$mtime
    fi
  done
  [ -n "$newest" ] || return 1
  printf '%s\n' "$newest"
}

describe_idle() {
  local seconds=$1
  if [ "$seconds" -ge 3600 ]; then
    printf '%sh\n' $((seconds / 3600))
  else
    printf '%sm\n' $((seconds / 60))
  fi
}

# examine <session> <state dir>
examine() {
  local session=$1 dir=$2 pid_file="$2/bridge.pid" pid last now idle
  [ -f "$pid_file" ] || { note "$session: skipped: no bridge record"; return 0; }
  if ! pid=$(fm_browser_session_bridge_pid "$pid_file"); then
    report "$session: skipped: bridge record names no readable pid ($pid_file)"
    return 0
  fi
  if ! fm_browser_session_is_bridge "$pid"; then
    note "$session: skipped: recorded pid $pid is not a running bridge"
    return 0
  fi
  if protected_session "$session"; then
    note "$session: skipped: a firstmate home records it as a live task's browser session"
    return 0
  fi
  if ! last=$(newest_state_mtime "$dir"); then
    report "$session: skipped: bridge pid $pid is running but its state could not be read ($dir)"
    return 0
  fi
  now=$(date +%s)
  idle=$((now - last))
  if [ "$idle" -lt "$AGE_SECONDS" ]; then
    note "$session: skipped: used within $AGE_WINDOW"
    return 0
  fi
  # Last, because it is the only check that costs a walk of every home's
  # backlog, and because nothing may be reported without it.
  fleet_index_usable || return 0
  if fleet_task_session "$session"; then
    note "$session: skipped: an open work item in the fleet still owns this session"
    return 0
  fi
  report "$session: idle: bridge pid $pid unused for $(describe_idle "$idle") (window $AGE_WINDOW); stop it with CHROME_DEVTOOLS_AXI_SESSION=$session chrome-devtools-axi stop"
}

[ -d "$ROOT_DIR" ] || exit 0

if [ "$PS_USABLE" -eq 0 ]; then
  report "$ROOT_DIR: skipped: running processes could not be identified, so an idle bridge cannot be told from a reused pid"
  exit 0
fi

# The legacy top-level record is the "default" session's; named sessions each
# get their own directory. Both are examined, because "default" is exactly the
# name an unpinned crewmate call leaves behind.
examine default "$ROOT_DIR"

if [ -d "$ROOT_DIR/sessions" ]; then
  for session_dir in "$ROOT_DIR"/sessions/*; do
    [ -d "$session_dir" ] || continue
    examine "${session_dir##*/}" "$session_dir"
  done
fi

exit 0
