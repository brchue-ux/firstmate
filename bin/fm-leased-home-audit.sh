#!/usr/bin/env bash
# fm-leased-home-audit.sh - report every secondmate home that an ordinary pool
# allocation could be handed, plus any task already recorded inside one.
#
# A persistent secondmate home and a disposable task worktree come from the same
# treehouse pool; only the home's durable lease keeps them apart. This audit
# answers the two questions that lease raises:
#
#   1. Is every registered home still leased to its own secondmate? A home that
#      is not is handed out by the next ordinary `treehouse get`.
#   2. Does any task's recorded worktree= already name a registered home? That is
#      a collision that has already happened, and tearing that task down would
#      release the home's lease and kill the secondmate's processes.
#
# Read-only: it inspects records and `treehouse status --json` and changes
# nothing. bin/fm-leased-home-lib.sh owns the identity and lease predicates.
#
# Usage:
#   fm-leased-home-audit.sh [--quiet] [<registry>...]
#
#   --quiet      print only problems, not the per-home OK lines
#   <registry>   extra data/secondmates.md files to audit, for sweeping another
#                firstmate home's registry from here. This home's own registry is
#                always audited first.
#
# Output lines are one of:
#   OK: <id> <home> leased
#   OK: <id> <home> not pooled (no lease to lose)
#   UNTRACKED: <id> <home> is a pool worktree its pool has no record of
#   LOST_LEASE: <id> <home> is <status>, so an ordinary acquisition can take it
#   HOLDER_MISMATCH: <id> <home> is leased to <holder>
#   COLLISION: task <task-id> records worktree=<home>, the home of <id>
#   UNKNOWN: <id> <home> home directory is missing
#   UNKNOWN: <id> <home> pool state could not be read
#
# UNTRACKED is a definite claim about what the pool records say, so it is only
# reported when at least one of the two readers actually answered. When neither
# could be consulted - `treehouse` or `jq` missing, no pool state file to read -
# the home is UNKNOWN instead, because this audit is the diagnostic every home
# refusal points at and a fleet-wide false alarm there is worse than no answer.
#
# Exit status: 0 when every home is protected and uncollided, 1 otherwise, so it
# can gate a script. Anything it reports is repaired through the
# secondmate-provisioning skill, never by hand-editing pool state.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=bin/fm-home-anchor-lib.sh
. "$SCRIPT_DIR/fm-home-anchor-lib.sh"
fm_home_anchor_resolve "$FM_ROOT" || exit 1
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-leased-home-lib.sh
. "$SCRIPT_DIR/fm-leased-home-lib.sh"

QUIET=0
REGISTRIES=()
for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=1 ;;
    -h|--help) sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "fm-leased-home-audit.sh: unknown option $arg" >&2; exit 2 ;;
    *) REGISTRIES+=("$arg") ;;
  esac
done
set -- "$DATA/secondmates.md" ${REGISTRIES+"${REGISTRIES[@]}"}

PROBLEMS=0

report_problem() {
  PROBLEMS=$((PROBLEMS + 1))
  printf '%s\n' "$1"
}

report_ok() {
  [ "$QUIET" = 1 ] || printf '%s\n' "$1"
}

# Report one home's lease. The live pool listing is preferred because it is
# treehouse's own public answer, but it only covers the pool the backing repo
# resolves to today, so a home in any other pool of that repo falls back to that
# pool's own durable records rather than being called unpooled.
audit_home() {  # <id> <home>
  local id=$1 home=$2 abs backing pool status holder path record record_rc
  local found_status="" found_holder="" consulted=0
  abs=$(fm_leased_home_abs "$home") || return 0
  if [ ! -d "$abs" ]; then
    report_problem "UNKNOWN: $id $abs home directory is missing"
    return 0
  fi
  # A home seeded at an explicit path is a plain clone, never a pool slot, so it
  # has no lease to lose and nothing can recycle it.
  if ! fm_leased_home_is_linked_worktree "$abs"; then
    report_ok "OK: $id $abs not pooled (no lease to lose)"
    return 0
  fi
  if backing=$(fm_leased_home_backing_repo "$abs") \
     && pool=$(fm_leased_home_pool_status "$backing"); then
    consulted=1
    while IFS=$'\t' read -r status holder path; do
      [ -n "$path" ] || continue
      path=$(fm_leased_home_abs "$path") || continue
      [ "$path" = "$abs" ] || continue
      found_status=$status
      found_holder=$holder
    done <<< "$pool"
  fi
  if [ -z "$found_status" ]; then
    if record=$(fm_leased_home_pool_state_record "$abs"); then
      consulted=1
      IFS=$'\t' read -r found_status found_holder <<< "$record"
    else
      record_rc=$?
      [ "$record_rc" -eq 2 ] || consulted=1
    fi
  fi
  if [ -z "$found_status" ]; then
    if [ "$consulted" = 0 ]; then
      report_problem "UNKNOWN: $id $abs pool state could not be read"
      return 0
    fi
    report_problem "UNTRACKED: $id $abs is a pool worktree its pool has no record of, so its slot can be reallocated"
    return 0
  fi
  if [ "$found_status" != leased ]; then
    report_problem "LOST_LEASE: $id $abs is $found_status, so an ordinary acquisition can take it"
  elif [ "$found_holder" != "$id" ]; then
    report_problem "HOLDER_MISMATCH: $id $abs is leased to $found_holder"
  else
    report_ok "OK: $id $abs leased"
  fi
}

# Any task record that already points at a registered home is a live collision:
# teardown would release that home's lease and kill the secondmate's processes.
audit_task_collisions() {  # <registry...>
  local meta task_id wt id
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    task_id=$(basename "$meta" .meta)
    wt=$(sed -n 's/^worktree=//p' "$meta" | head -1)
    [ -n "$wt" ] || continue
    id=$(fm_leased_home_owner "$wt" "$@") || continue
    # A secondmate's own record naming its own home is the normal case.
    if [ "$id" = "$task_id" ]; then
      continue
    fi
    report_problem "COLLISION: task $task_id records worktree=$(fm_leased_home_abs "$wt"), the home of $id"
  done
}

seen_any=0
for registry in "$@"; do
  [ -f "$registry" ] || continue
  while IFS=$'\t' read -r entry_id entry_home; do
    [ -n "$entry_id" ] && [ -n "$entry_home" ] || continue
    seen_any=1
    audit_home "$entry_id" "$entry_home"
  done < <(fm_leased_home_registry_entries "$registry")
done

audit_task_collisions "$@"

if [ "$seen_any" = 0 ] && [ "$QUIET" = 0 ]; then
  echo "OK: no registered secondmate homes to audit"
fi

[ "$PROBLEMS" = 0 ] || exit 1
