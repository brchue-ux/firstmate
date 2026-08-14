#!/usr/bin/env bash
# Removal of the side-effect artifacts a task record owns OUTSIDE state/<id>.meta.
#
# Deleting state/<id>.* is never the whole retirement. Three of those records are
# pointers into files that live elsewhere and outlive them:
#
#   - state/<id>.<harness>-turnend-token names a firstmate-owned authorization
#     file under the harness's global hooks dir. The token string exists ONLY in
#     that record, so unlinking the record first strands the authorization
#     permanently - it still authorizes a turn-end touch for a task id that no
#     longer exists, and nothing can ever locate the file again to remove it.
#   - the PR-check artifacts have a hardened removal protocol (a symlink,
#     hardlink, cross-device or bad-mode artifact REFUSES and preserves task
#     state rather than being force-removed) plus a quarantine directory a plain
#     `rm -f` of the five state records leaves behind.
#   - state/<id>.meta's `tasktmp=` line names the per-task temp root. The path
#     exists only in that record, and bin/fm-tmp-sweep.sh's candidate glob does
#     not match this root's shape, so unlinking the meta first orphans it with
#     nothing left able to reclaim it.
#
# bin/fm-teardown.sh is the original owner of these predicates and still their
# only ordinary-lifecycle caller. They live here because
# bin/fm-collided-record-clear.sh retires the one class of record teardown
# refuses outright, and a second retirement path that only approximated this
# would reintroduce exactly the dead-task-wake and orphaned-artifact classes the
# originals exist to prevent.
#
# Ordering contract for every caller: run remove_pr_poll_artifacts FIRST, because
# it is the only one of these that can REFUSE, and its refusal is meaningful only
# while the rest of the task record is still intact; then the turn-end
# authorizations and the temp root, while the records naming them still exist;
# and only then unlink state/<id>.*.
#
# bin/fm-pr-lib.sh owns the PR-artifact safety predicates this consults. This
# file is sourced and has no side effects on source.

FM_TASK_RECORD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Remove the per-task temp root bin/fm-spawn.sh recorded as `tasktmp=`.
#
# The path is read out of a file rather than computed, so its shape is proven
# before an `rm -rf` acts on it: spawn builds it as <absolute root>/fm-<id> and
# refuses a relative FM_TASK_TMP_ROOT for this exact reason, so anything that is
# not an absolute path ending in the caller's own fm-<id>, and not a plain
# directory, is refused and left in place rather than removed on trust.
remove_task_tmp_root() {  # <task-tmp> <id>
  local task_tmp=$1 id=$2
  [ -n "$task_tmp" ] || return 0
  case "$task_tmp" in
    /*) ;;
    *)
      echo "REFUSED: recorded tasktmp=$task_tmp is not an absolute path; leaving it in place." >&2
      return 1 ;;
  esac
  if [ "${task_tmp##*/}" != "fm-$id" ]; then
    echo "REFUSED: recorded tasktmp=$task_tmp is not task $id's temp root (expected a directory named fm-$id); leaving it in place." >&2
    return 1
  fi
  { [ -e "$task_tmp" ] || [ -L "$task_tmp" ]; } || return 0
  if [ ! -d "$task_tmp" ] || [ -L "$task_tmp" ]; then
    echo "REFUSED: recorded tasktmp=$task_tmp is not a plain directory; leaving it in place." >&2
    return 1
  fi
  rm -rf -- "$task_tmp"
}

remove_grok_turnend_auth() {
  local state_dir=$1 id=$2 token hooks_dir
  token=$(cat "$state_dir/$id.grok-turnend-token" 2>/dev/null || true)
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  hooks_dir="${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d"
  rm -f "$hooks_dir/$token"
}

remove_kimi_turnend_auth() {
  local state_dir=$1 id=$2 token hooks_dir
  token=$(cat "$state_dir/$id.kimi-turnend-token" 2>/dev/null || true)
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  hooks_dir="$HOME/.kimi-code/fm-turn-end.d"
  rm -f "$hooks_dir/$token"
}

validate_pr_poll_cleanup() {
  local state_dir=$1 id=$2 quarantine state_device artifact has_artifact=0
  fm_task_id_path_safe "$id" || return 0
  quarantine="$state_dir/.pr-check-quarantine"
  if [ "$id" = _noncanonical ] \
    && { [ -e "$quarantine/_noncanonical.diagnostic.pending-noncanonical" ] \
      || [ -L "$quarantine/_noncanonical.diagnostic.pending-noncanonical" ] \
      || [ -e "$quarantine/_noncanonical.diagnostic.noncanonical" ] \
      || [ -L "$quarantine/_noncanonical.diagnostic.noncanonical" ]; }; then
    echo "REFUSED: legacy PR-check quarantine migration is incomplete; preserving task state." >&2
    return 1
  fi
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    has_artifact=1
  done
  if [ -e "$quarantine" ] || [ -L "$quarantine" ]; then
    has_artifact=1
  fi
  [ "$has_artifact" -eq 1 ] || return 0
  [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || return 1
  state_device=$(fm_pr_file_device "$state_dir") || return 1
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if [ ! -f "$artifact" ] || [ -L "$artifact" ] \
      || [ "$(fm_pr_file_device "$artifact")" != "$state_device" ] \
      || [ "$(fm_pr_file_link_count "$artifact")" != 1 ]; then
      echo "REFUSED: unsafe task PR-check artifact; preserving task state." >&2
      return 1
    fi
  done
  if [ -e "$state_dir/$id.pr-poll-retirement" ] \
    || [ -L "$state_dir/$id.pr-poll-retirement" ]; then
    fm_pr_poll_retirement_state_valid "$state_dir" "$id" || {
      echo "REFUSED: invalid PR-poll retirement receipt; preserving task state." >&2
      return 1
    }
  fi
  [ -e "$quarantine" ] || [ -L "$quarantine" ] || return 0
  if [ ! -d "$state_dir" ] || [ -L "$state_dir" ] \
    || [ ! -d "$quarantine" ] || [ -L "$quarantine" ]; then
    echo "REFUSED: unsafe PR-check quarantine path $quarantine; preserving task state." >&2
    return 1
  fi
  if [ "$(fm_pr_file_device "$quarantine")" != "$state_device" ] \
    || [ "$(fm_pr_file_mode "$quarantine")" != 700 ]; then
    echo "REFUSED: PR-check quarantine is not on the task state device; preserving task state." >&2
    return 1
  fi
  for artifact in "$quarantine/$id."*; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if ! fm_pr_private_file_valid "$artifact" 600 "$state_device"; then
      echo "REFUSED: unsafe task quarantine entry; preserving task state." >&2
      return 1
    fi
  done
}

remove_pr_poll_artifacts() {
  local state_dir=$1 id=$2 quarantine artifact
  validate_pr_poll_cleanup "$state_dir" "$id" || return 1
  fm_pr_poll_retirement_recover_one "$state_dir" "$id" \
    "$FM_TASK_RECORD_LIB_DIR/fm-pr-poll.sh" || return 1
  rm -f "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.check-trust" || return 1
  if fm_task_id_path_safe "$id"; then
    quarantine="$state_dir/.pr-check-quarantine"
    if [ -d "$quarantine" ] && [ ! -L "$quarantine" ]; then
      for artifact in "$quarantine/$id."*; do
        [ -e "$artifact" ] || [ -L "$artifact" ] || continue
        rm -f -- "$artifact" || return 1
      done
      rmdir "$quarantine" 2>/dev/null || true
    fi
  fi
}
