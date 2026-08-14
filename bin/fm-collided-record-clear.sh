#!/usr/bin/env bash
# fm-collided-record-clear.sh - retire ONE already-collided task record whose
# recorded worktree= names another secondmate's persistent home.
#
# bin/fm-teardown.sh refuses such a record outright, and must: its treehouse
# return would release that home's durable lease and its cleanup would strip the
# home's turn-end hooks. That refusal deliberately has no bypass and --force does
# not reach it, which leaves the collided record itself with no supported way
# out - and hand-editing state/<id>.meta is the exact repair that produced the
# original collision. This command is that way out, and nothing more.
#
# What it removes: this home's own state/<id>.* task records, plus the three
# classes of artifact those records are pointers into - the harness turn-end
# authorization file, the PR-check artifacts, and the per-task temp root the
# meta records as tasktmp= - through the same hardened helpers
# bin/fm-teardown.sh uses, which bin/fm-task-record-lib.sh owns. That sharing is
# the point: a token record unlinked without its authorization file strands a
# turn-end wake for a task id that no longer exists, and this command is the
# ONLY remaining owner of a collided record's id.
# Nothing else. It never touches the home the record names - not its files, not
# its processes, not its treehouse lease - and it never touches the backend
# endpoint. Closing a window the cleared record used to name is the operator's
# call afterwards; the recorded endpoint is printed so it can be found.
#
# A PR-check artifact that is a symlink, is hardlinked, or sits on a different
# device REFUSES and preserves the whole task record, exactly as in teardown; the
# refusal is raised before anything at all is removed. A recorded tasktmp= that
# is not an absolute per-task temp root named fm-<task-id>, or that resolves
# inside the home, is refused rather than removed on the meta's word.
#
# It refuses unless the recorded worktree= really does resolve to a secondmate
# home that this task does not own, decided by bin/fm-leased-home-lib.sh from the
# home's own .fm-secondmate-home marker and data/secondmates.md. A record naming
# an ordinary worktree, or a secondmate's record naming its own home, is retired
# through bin/fm-teardown.sh and is refused here, so this can never become a
# general-purpose meta deleter.
#
# Usage:
#   fm-collided-record-clear.sh <task-id>
#
# Run bin/fm-leased-home-audit.sh first: it reports every COLLISION of this shape
# by task id, and re-run it afterwards to confirm the collision is gone.
#
# Exit status: 0 when the record was cleared, 1 on any refusal.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=bin/fm-home-anchor-lib.sh
. "$SCRIPT_DIR/fm-home-anchor-lib.sh"
fm_home_anchor_resolve "$FM_ROOT" || exit 1
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SECONDMATE_REG="$DATA/secondmates.md"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-task-record-lib.sh
. "$SCRIPT_DIR/fm-task-record-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-leased-home-lib.sh
. "$SCRIPT_DIR/fm-leased-home-lib.sh"

case "${1:-}" in
  -h|--help) sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

[ "$#" -eq 1 ] || { echo "usage: fm-collided-record-clear.sh <task-id>" >&2; exit 2; }
ID=$1
fm_task_id_path_safe "$ID" || { echo "error: invalid task id '$ID'" >&2; exit 2; }
fm_refuse_if_gate_agent

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

WT=$(sed -n 's/^worktree=//p' "$META" | head -1)
if [ -z "$WT" ]; then
  echo "REFUSED: task $ID records no worktree=, so there is no collision to clear here." >&2
  echo "Retire an ordinary task record through bin/fm-teardown.sh $ID." >&2
  exit 1
fi

if ! OWNER=$(fm_leased_home_owner "$WT" "$SECONDMATE_REG"); then
  echo "REFUSED: task $ID records worktree=$WT, which is not a registered or marked secondmate home." >&2
  echo "This command clears only a record that collides with another agent's home; retire an ordinary task through bin/fm-teardown.sh $ID." >&2
  exit 1
fi

if [ "$OWNER" = "$ID" ]; then
  echo "REFUSED: task $ID records its OWN home $WT, which is not a collision." >&2
  echo "A secondmate's home is retired through bin/fm-teardown.sh $ID, which returns its lease." >&2
  exit 1
fi

ENDPOINT=$(sed -n 's/^window=//p' "$META" | head -1)
[ -n "$ENDPOINT" ] || ENDPOINT=$(sed -n 's/^terminal=//p' "$META" | head -1)
TASK_TMP=$(sed -n 's/^tasktmp=//p' "$META" | head -1)

# The temp root is the one recorded path that could be made to point INSIDE the
# home, which this command may never touch. bin/fm-task-record-lib.sh proves the
# shape; the boundary is proven here, where the home is known.
if [ -n "$TASK_TMP" ]; then
  TASK_TMP_ABS=$(fm_leased_home_abs "$TASK_TMP") || TASK_TMP_ABS=$TASK_TMP
  HOME_ABS=$(fm_leased_home_abs "$WT") || HOME_ABS=$WT
  case "$TASK_TMP_ABS" in
    "$HOME_ABS"|"$HOME_ABS"/*)
      echo "REFUSED: task $ID records tasktmp=$TASK_TMP, which is inside secondmate '$OWNER' home $WT." >&2
      echo "This command never touches that home; correct the tasktmp= line in $META, then re-run." >&2
      exit 1 ;;
  esac
fi

# Every removal below is confined to this home's own state/ directory and to the
# firstmate-owned files its records point at, in the order
# bin/fm-task-record-lib.sh's contract requires: the refusing PR-check protocol
# first, so its refusal leaves the whole record intact, then the turn-end
# authorizations and the temp root while the records naming them still exist,
# then the records.
remove_pr_poll_artifacts "$STATE" "$ID" || exit 1
remove_grok_turnend_auth "$STATE" "$ID"
remove_kimi_turnend_auth "$STATE" "$ID"
remove_task_tmp_root "$TASK_TMP" "$ID" || exit 1

# Enumerated rather than globbed on "$ID."*: a task id may contain a dot, so a
# glob could reach a differently-named task's records.
for suffix in status turn-ended meta pi-ext.ts grok-turnend-token \
  kimi-turnend-token herdr-presentation; do
  record="$STATE/$ID.$suffix"
  { [ -e "$record" ] || [ -L "$record" ]; } || continue
  rm -f -- "$record"
  echo "cleared $record"
done

echo "cleared the collided record for task $ID; secondmate '$OWNER' home $WT was not touched."
if [ -n "$ENDPOINT" ]; then
  echo "That record named endpoint $ENDPOINT; close it yourself if it is still open."
fi
