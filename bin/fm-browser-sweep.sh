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
# session (bin/fm-brief.sh pins it per task and owning home), but a crewmate
# that was
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
#   - no home records it as a live task's session. A session pinned to a task
#     whose state/<task id>.meta still exists belongs to work in flight -
#     including a task deliberately idling on an external wait - and a long-idle
#     browser is normal there. The homes read are every home the fleet index
#     below resolved, plus any named with --protect-home; a task is only ever
#     recorded in its own home, so reading one home would leave every other
#     home's meta-only work unprotected
#   - nothing in the session's own state has been written within the age window
#   - no open work item anywhere in the fleet owns the session. Bridge state is
#     host-global, so a session can belong to a live worker in a secondmate home
#     this sweep knows nothing about; bin/fm-fleet-work-index.sh already answers
#     "what is open anywhere", transitively and read-only, so it is consulted
#     once per run and every open item's pinned session name is protected.
#     Session names are derived FORWARD through bin/fm-browser-session-lib.sh
#     from each item's id AND the home that owns it, never parsed back out of a
#     name: a name carries its home's tag and, once shortened, a digest where
#     the rest of the id was, so nothing can recover an id from one. Deriving
#     with this sweep's own home instead would build names no other home's
#     crewmate ever used, and quietly protect nothing outside this home.
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
# RUN THIS FROM THE FLEET ROOT. The index walks strictly downward from the home
# it is run in, through that home's data/secondmates.md and onward; it has no
# parent pointer, so run from a secondmate home it returns that home's own
# subtree and reports it as a COMPLETE answer. Nothing in the output can mark
# that gap, because from down there the rest of the fleet is not visible to be
# missed. A sweep run from a secondmate home therefore knows nothing about the
# primary's open work while reading the same host-global bridge state, and would
# report a live sibling worker's browser as an orphan. bin/fm-bootstrap.sh runs
# this in the main home only for exactly that reason, and the main home's run
# covers the whole host on every home's behalf. This is a caveat on where a
# manual run is meaningful, not a refusal: the script stays runnable anywhere.
#
# The two ownership layers are complementary, and each covers what the other
# cannot: the index knows a task by its open backlog ROW in any home, while the
# live-task layer knows it by its state/<id>.meta RECORD in any home the index
# resolved. A task dispatched straight from a conversation has a record and no
# row; a queued item has a row and no record. Reading the records of only one
# home left everything between them exposed, which is why the record layer
# follows the index's own home list rather than the command line.
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
#   FM_BROWSER_SWEEP_HOMES        firstmate homes whose live tasks are protected
#                                 in ADDITION to the ones the fleet index
#                                 resolves, colon-separated
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

SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"

# Portable mtime has one owner in this repo; a second copy would drift.
# shellcheck source=bin/fm-supervision-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# The task-id-to-session-name derivation has one owner too: bin/fm-brief.sh
# writes the name, bin/fm-teardown.sh stops it, and this derives it back for
# every open task in the fleet. A second copy would drift into names that never
# match, which here means reporting a live worker's browser. That same library
# owns where chrome-devtools-axi keeps its state, which is why it is sourced
# before the default below rather than after the argument parsing.
# shellcheck source=bin/fm-browser-session-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-browser-session-lib.sh"

FLEET_INDEX_CMD="$SCRIPT_DIR/fm-fleet-work-index.sh"

AGE_HOURS=${FM_BROWSER_SWEEP_AGE_HOURS:-12}
AGE_MINUTES_OPT=${FM_BROWSER_SWEEP_AGE_MINUTES:-}
# The state root has ONE owner, and it is the library above - the same one
# bin/fm-teardown.sh reads through fm_browser_session_has_live_bridge. A second
# independent default here is how a caller redirects this sweep and still leaves
# teardown reading the real ~/.chrome-devtools-axi. FM_BROWSER_SWEEP_ROOT stays
# as the sweep's own documented override, but redirecting the library's variable
# alone is enough to move both readers together.
ROOT_DIR=${FM_BROWSER_SWEEP_ROOT:-$(fm_browser_session_root)}
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
# Every home the index READ, newline-separated, which is what lets the live-task
# layer below cover the whole fleet rather than only the homes named on the
# command line. The index already resolved them, so this costs nothing extra.
FLEET_INDEX_HOMES=

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
  local json ids id home rc unread
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

  # Each item carries the home that owns it, and the session name is derived
  # from BOTH: a task id is unique only inside its home, while the browser
  # session namespace is host-global. Deriving with this sweep's own home would
  # produce names no other home's crewmate ever used, so every open task
  # elsewhere in the fleet would silently stop being protected.
  ids=$(printf '%s' "$json" | jq -r '
    .items[] | select((.id // "") != "") | "\(.id)\t\(.home // "")"' 2>/dev/null) || {
    FLEET_INDEX_REASON="the cross-home work index did not emit a readable fm-fleet-work-index.v1 object"
    return 1
  }

  # The homes themselves, every one the index resolved - including the ones it
  # skipped, which are exactly where the gap this closes lives: a home with no
  # backlog file is skipped as a complete answer about its BACKLOG, and is also
  # the likeliest home to be running a task that only ever existed as a
  # state/<id>.meta. Nothing is inferred about a skipped home's work here; its
  # live task records are simply read directly, one directory listing each.
  FLEET_INDEX_HOMES=$(printf '%s' "$json" | jq -r '
    .homes[] | select((.home // "") != "") | .home' 2>/dev/null) || {
    FLEET_INDEX_REASON="the cross-home work index did not emit a readable fm-fleet-work-index.v1 object"
    return 1
  }
  # The _result form derives in THIS shell rather than a command substitution,
  # so the library's per-home tag memo survives from one item to the next. A
  # fleet with 206 open items across 19 homes otherwise pays 206 subshells and
  # digests for 19 distinct answers, on a path that runs at session start.
  FLEET_TASK_SESSIONS=" "
  while IFS=$'\t' read -r id home; do
    [ -n "$id" ] || continue
    fm_browser_session_name_result "$id" "$home" || continue
    FLEET_TASK_SESSIONS="$FLEET_TASK_SESSIONS$FM_BROWSER_SESSION_NAME_RESULT "
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

# A session pinned to a task a home still records is live work's, however long
# its browser has sat untouched: state/<task id>.meta exists exactly as long as
# the task does. This is the second layer under the fleet index, not a duplicate
# of it - a task can hold a meta with no backlog row at all (a scout dispatched
# straight from a conversation), and that is still work in flight.
#
# The homes walked are every home the fleet index resolved, plus any named with
# --protect-home. Reading only the named ones left the two layers with a gap
# between them: the index sees a task by its backlog ROW, so a meta-only task in
# any home but this one was covered by neither, and its browser was reported as
# an orphan with a stop command attached - measured at 25 such live records on
# one host. The index has already resolved every home by the time this runs, so
# closing that gap is one directory listing per home and no new discovery path.
# --protect-home remains for a manual run against homes outside the index.
#
# The direction is id -> name, never name -> id. A session name carries its
# home's tag and, once shortened, a digest where the rest of the id was
# (bin/fm-browser-session-lib.sh), so no id can be recovered from one; deriving
# the name each recorded task would have used is the only comparison that holds.
# Each meta is derived against the home it was found in, for the same reason the
# fleet index items are: the same id in two homes is two different sessions.
PROTECTED_SESSIONS=
PROTECTED_SESSIONS_LOADED=0

load_protected_sessions() {
  local rest=$PROTECT_HOMES homes='' seen=$'\n' home meta id
  while [ -n "$rest" ]; do
    home=${rest%%:*}
    case "$rest" in
      *:*) rest=${rest#*:} ;;
      *) rest= ;;
    esac
    [ -n "$home" ] || continue
    homes="$homes$home"$'\n'
  done
  homes="$homes$FLEET_INDEX_HOMES"

  PROTECTED_SESSIONS=" "
  while IFS= read -r home; do
    [ -n "$home" ] || continue
    # A home reached from both sources is read once; the same meta yields the
    # same name either way, but the listing is not worth repeating.
    case "$seen" in
      *$'\n'"$home"$'\n'*) continue ;;
    esac
    seen="$seen$home"$'\n'
    [ -d "$home/state" ] || continue
    for meta in "$home"/state/*.meta; do
      [ -f "$meta" ] || continue
      id=${meta##*/}
      id=${id%.meta}
      fm_browser_session_name_result "$id" "$home" || continue
      PROTECTED_SESSIONS="$PROTECTED_SESSIONS$FM_BROWSER_SESSION_NAME_RESULT "
    done
  done <<<"$homes"
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
  local session=$1 dir=$2 pid_file="$2/bridge.pid" pid last now idle unreadable=
  [ -f "$pid_file" ] || { note "$session: skipped: no bridge record"; return 0; }
  if ! pid=$(fm_browser_session_bridge_pid "$pid_file"); then
    report "$session: skipped: bridge record names no readable pid ($pid_file)"
    return 0
  fi
  if ! fm_browser_session_is_bridge "$pid"; then
    note "$session: skipped: recorded pid $pid is not a running bridge"
    return 0
  fi
  if last=$(newest_state_mtime "$dir"); then
    now=$(date +%s)
    idle=$((now - last))
    if [ "$idle" -lt "$AGE_SECONDS" ]; then
      note "$session: skipped: used within $AGE_WINDOW"
      return 0
    fi
  else
    # Unreadable state cannot be aged, but it still describes a live bridge an
    # operator may act on, so it goes through the same ownership checks below
    # rather than being announced about a session live work still owns.
    unreadable="bridge pid $pid is running but its state could not be read ($dir)"
  fi
  # The ownership checks come last: the index is the only one that costs a walk
  # of every home's backlog, nothing may be reported without it, and the live-
  # task layer under it reads the homes the index resolved.
  fleet_index_usable || return 0
  if fleet_task_session "$session"; then
    note "$session: skipped: an open work item in the fleet still owns this session"
    return 0
  fi
  if protected_session "$session"; then
    note "$session: skipped: a firstmate home records it as a live task's browser session"
    return 0
  fi
  if [ -n "$unreadable" ]; then
    report "$session: skipped: $unreadable"
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
