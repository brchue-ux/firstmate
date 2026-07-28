#!/usr/bin/env bash
# fm-become.sh - turn THIS space into a registered secondmate, in place.
#
# The counterpart to "fm-spawn.sh --secondmate". Spawn launches a secondmate
# into a NEW backend target; become REPLACES the current pane's harness with one
# rooted in the secondmate's own home, so a captain who opened a plain session
# can hand that same space to a project without a second window appearing.
#
# Why this exists: FM_HOME - not the working directory - selects a home and its
# session lock. A harness launched anywhere without FM_HOME resolves to the
# primary home and contends for the ONE primary lock, so several plain sessions
# collapse onto a single wheel and every loser is read-only. Re-execing with
# FM_HOME set moves this session onto a lock nothing else holds.
#
# This is a PROCESS REPLACEMENT: the current harness is killed and its
# conversation is gone. The target home is left a one-shot handover notice
# (state/.fm-handover-notice) so the incoming session states plainly that it
# carries no context from the session that handed off.
#
# Usage: fm-become.sh <secondmate-id>
#        fm-become.sh --list
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/secondmates.md"
MARKER_NAME=".fm-secondmate-home"
NOTICE_NAME=".fm-handover-notice"

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

die() { echo "error: $*" >&2; exit 1; }

# The registry lives only in the primary home, so a session already rooted in a
# secondmate home has nothing to resolve against. Say that plainly instead of
# reporting the missing registry that is its symptom.
if [ -f "$FM_HOME/$MARKER_NAME" ] && [ ! -L "$FM_HOME/$MARKER_NAME" ]; then
  IFS= read -r CURRENT_ID < "$FM_HOME/$MARKER_NAME" 2>/dev/null || CURRENT_ID=
  CURRENT_ID=${CURRENT_ID//[[:space:]]/}
  die "this session is already the '${CURRENT_ID:-unknown}' secondmate; run fm-become.sh from a plain or primary session"
fi

[ -f "$REG" ] || die "no secondmate registry at $REG"

# Print "<id>\t<home>" for every registry entry that carries a home path.
registry_rows() {
  awk '
    $1 == "-" && $2 != "" && match($0, /\(home: [^;]+;/) {
      printf "%s\t%s\n", $2, substr($0, RSTART + 7, RLENGTH - 8)
    }
  ' "$REG"
}

if [ "${1-}" = "--list" ]; then
  registry_rows
  exit 0
fi

ID=${1:?usage: fm-become.sh <secondmate-id>  (--list to see ids)}

TARGET=$(registry_rows | awk -F'\t' -v n="$ID" '$1 == n { print $2; exit }')
[ -n "$TARGET" ] || die "no secondmate '$ID' in $REG; run 'fm-become.sh --list' for ids"

# The registry names the home; the home's own marker is what makes it one.
# Both must agree, so a stale or hand-edited registry line cannot redirect a
# session into a home that is not the secondmate it claims.
[ -d "$TARGET" ] || die "secondmate '$ID' home does not exist: $TARGET"
MARKER="$TARGET/$MARKER_NAME"
[ -f "$MARKER" ] && [ ! -L "$MARKER" ] || die "no $MARKER_NAME marker in $TARGET; not a seeded secondmate home"
IFS= read -r MARKED < "$MARKER" 2>/dev/null || die "cannot read $MARKER"
MARKED=${MARKED//[[:space:]]/}
[ "$MARKED" = "$ID" ] || die "$MARKER_NAME in $TARGET reads '$MARKED', not '$ID'; registry and home disagree"

# Becoming a home whose lock a LIVE harness already holds would just recreate
# the contention this script exists to remove, so refuse instead of handing the
# captain a second read-only session. A dead pid in the file is inert and fine.
TARGET_STATE="$TARGET/state"
if [ -f "$TARGET_STATE/.lock" ]; then
  IFS= read -r HOLDER < "$TARGET_STATE/.lock" 2>/dev/null || HOLDER=
  case "$HOLDER" in
    ''|*[!0-9]*) ;;
    *) fm_harness_pid_alive "$HOLDER" && die "secondmate '$ID' is already live in another space (pid $HOLDER)" ;;
  esac
fi

RESOLVED_HOME=$(cd "$FM_HOME" 2>/dev/null && pwd) || RESOLVED_HOME=$FM_HOME
RESOLVED_TARGET=$(cd "$TARGET" && pwd)
[ "$RESOLVED_HOME" != "$RESOLVED_TARGET" ] || die "this session is already the '$ID' secondmate"

[ -n "${TMUX_PANE:-}" ] || die "not running inside a tmux pane; fm-become.sh replaces the current pane in place"

HARNESS=$(command -v claude) || die "cannot find the claude harness on PATH"

mkdir -p "$TARGET_STATE" 2>/dev/null || die "cannot create $TARGET_STATE"
printf '%s\n' "$ID" > "$TARGET_STATE/$NOTICE_NAME" || die "cannot write the handover notice"

# FM_ALLOW_SUBAGENT is a deliberate, captain-authorized exception: these project
# spaces may use the harness's own delegation tools in addition to dispatching
# crewmates through the fleet.
CMD=$(printf 'cd %q && exec env FM_HOME=%q FM_ALLOW_SUBAGENT=1 %q' \
  "$RESOLVED_TARGET" "$RESOLVED_TARGET" "$HARNESS")

echo "becoming secondmate '$ID' in $RESOLVED_TARGET (this conversation ends here)" >&2
exec tmux respawn-pane -k -t "$TMUX_PANE" "$CMD"
