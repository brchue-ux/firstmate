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
#     process. A pid the OS has reused for something else is not this tool's, and
#     reporting it would send an operator to kill an unrelated process
#   - no --protect-home records it as a live task's session. A session named
#     fm-<task id> whose state/<task id>.meta still exists belongs to work in
#     flight - including a task deliberately idling on an external wait - and a
#     long-idle browser is normal there
#   - nothing in the session's own state has been written within the age window
# Idle is measured from that state, not from process age: a bridge started two
# days ago and used a minute ago is in use, and reporting it as an orphan is the
# error that gets a live session killed.
#
# Scope limit, stated because it decides what an operator can trust: bridge state
# is host-global while --protect-home is per home, so a session belonging to
# ANOTHER home's live task is still reported here. The lines are advisory, and
# the operator confirms ownership before stopping anything.
#
# Output is one line per notable outcome and silent otherwise, in the same
# "<subject>: <verb>: <detail>" shape the other session-start sweeps use:
#   "<session>: idle: <detail>"    - a bridge nothing has used for the window,
#                                    with the session-scoped stop command
#   "<session>: skipped: <reason>" - a bridge record that could not be read, so
#                                    idleness could not be decided either way
#   "<root>: skipped: <reason>"    - a whole-sweep limit (running processes could
#                                    not be identified at all)
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

# Portable mtime has one owner in this repo; a second copy would drift.
# shellcheck source=bin/fm-supervision-lib.sh disable=SC1091
. "$(cd "$(dirname "$SELF")" && pwd)/fm-supervision-lib.sh"

report() {
  printf '%s\n' "$1"
}

note() {
  [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$1"
  return 0
}

# The bridge record chrome-devtools-axi writes is {"pid":N,"port":P}. Only the
# pid is read here, without a jq dependency, and anything that does not parse to
# a plain number is treated as unreadable rather than guessed at.
bridge_pid() {
  local file=$1 pid
  pid=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$file" 2>/dev/null | head -n 1)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$pid"
}

# Whether ps can report on a running process at all. Without it a live bridge
# cannot be told apart from a pid the OS has since reused, and every line this
# sweep prints is an invitation to kill something - so the whole sweep says so
# and reports nothing instead of guessing.
PS_USABLE=1
if [ -z "$(ps -o args= -p $$ 2>/dev/null)" ]; then
  PS_USABLE=0
fi

is_bridge_process() {
  local pid=$1 args
  kill -0 "$pid" 2>/dev/null || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  case "$args" in
    *chrome-devtools-axi*) return 0 ;;
    *) return 1 ;;
  esac
}

# A session pinned to a task this home still records is live work's, however
# long its browser has sat untouched: bin/fm-brief.sh pins the name to fm-<task
# id>, and state/<task id>.meta exists exactly as long as the task does.
protected_session() {
  local session=$1 home task_id
  case "$session" in
    fm-*) task_id=${session#fm-} ;;
    *) return 1 ;;
  esac
  [ -n "$task_id" ] || return 1
  local IFS=:
  for home in $PROTECT_HOMES; do
    [ -n "$home" ] || continue
    if [ -f "$home/state/$task_id.meta" ]; then
      return 0
    fi
  done
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
  if ! pid=$(bridge_pid "$pid_file"); then
    report "$session: skipped: bridge record names no readable pid ($pid_file)"
    return 0
  fi
  if ! is_bridge_process "$pid"; then
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
    examine "$(basename "$session_dir")" "$session_dir"
  done
fi

exit 0
