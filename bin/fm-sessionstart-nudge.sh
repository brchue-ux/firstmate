#!/usr/bin/env bash
# Print the one-line session-start instruction only for a genuine firstmate
# primary whose current harness session has not already acquired the home lock.
# Every silence and error path exits 0 because Claude SessionStart exit 2 blocks
# session initialization.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"

fm_is_gate_agent "$FM_ROOT" && exit 0

# One-shot handover notice left by bin/fm-become.sh. Becoming a secondmate
# replaces the harness process, so the incoming session inherits none of the
# handing-off session's conversation and must say so rather than imply
# continuity. Consumed before the scope and lock gates below so a suppressed
# nudge never swallows it, and removed first so a failed encode cannot leave it
# to reappear at every later session start.
NOTICE="$STATE/.fm-handover-notice"
if [ -f "$NOTICE" ] && [ ! -L "$NOTICE" ]; then
  IFS= read -r notice_id < "$NOTICE" 2>/dev/null || notice_id=
  rm -f "$NOTICE" 2>/dev/null || true
  notice_id=${notice_id//[[:space:]]/}
  notice=
  if [ -n "$notice_id" ] && fm_operational_input_encode session-start \
    "This is a new session in the $notice_id secondmate home. It has no context from the firstmate session that handed off." \
    notice; then
    printf '%s\n' "$notice"
  fi
fi

fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

lock_is_in_ancestry() {
  local lock_pid pid=$$ _
  [ -f "$STATE/.lock" ] || return 1
  IFS= read -r lock_pid < "$STATE/.lock" 2>/dev/null || return 1
  case "$lock_pid" in
    ''|*[!0-9]*|1) return 1 ;;
  esac
  kill -0 "$lock_pid" 2>/dev/null || return 1
  for _ in 1 2 3 4 5 6 7 8; do
    [ "$pid" = "$lock_pid" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

lock_is_in_ancestry && exit 0
nudge=
fm_operational_input_encode session-start \
  "Run \`bin/fm-session-start.sh\` now, exactly once, before executing any other instructions." \
  nudge || exit 0
printf '%s\n' "$nudge"
exit 0
