#!/usr/bin/env bash
# Ownership predicates for the worktree-resident turn-end hook artifacts that
# bin/fm-spawn.sh writes and bin/fm-teardown.sh removes.
#
# A pool worktree outlives the task that used it. Teardown removes these files,
# but a task whose teardown never ran - or ran against a path that had since been
# reallocated to somebody else - leaves them in the slot, and the next occupant
# inherits a Stop hook that touches the turn-ended file of a task id that no
# longer exists, waking firstmate for a dead task on every single turn.
#
# Spawn writing its own hook does not fix that: it overwrites only the artifact
# ITS harness uses, and a kind=secondmate spawn writes none at all, so a leftover
# from a prior occupant is invisible to both paths. The sweep below is what
# clears it, and it has to run on every spawn and every kind.
#
# This file is sourced and has no side effects on source.

# Worktree-relative artifacts that carry a task identity.
#
# .grok/hooks/fm-turn-end.json is deliberately absent: it is task-agnostic and
# resolves its target through the .fm-grok-turnend pointer, so clearing the
# stale pointer already disarms it - the hook exits 0 when the pointer is gone.
FM_TURNEND_ARTIFACTS=".claude/settings.local.json
.opencode/plugins/fm-turn-end.js
.fm-grok-turnend
.fm-kimi-turnend"

# Print the task id a turn-end artifact belongs to, or nothing when the file is
# not a firstmate turn-end hook at all.
#
# The claude and opencode hooks embed the absolute state/<id>.turn-ended path
# they touch. The grok and kimi files are pointers naming this home's
# state/<id>.<harness>-turnend-token instead, so the id comes off that name.
fm_turnend_artifact_task_id() {  # <file>
  local file=$1 token
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  case "$file" in
    *.fm-grok-turnend|*.fm-kimi-turnend)
      token=$(sed -n 's/^token=//p' "$file" | head -1)
      [ -n "$token" ] || return 0
      token=${token##*/}
      case "$token" in
        *.grok-turnend-token) printf '%s\n' "${token%.grok-turnend-token}" ;;
        *.kimi-turnend-token) printf '%s\n' "${token%.kimi-turnend-token}" ;;
      esac
      ;;
    *)
      sed -n 's:.*/\([^/'"'"'" ]*\)\.turn-ended.*:\1:p' "$file" | head -1
      ;;
  esac
}

# Remove every turn-end artifact in <worktree> that names a task other than
# <this-task-id>, reporting each removal on stderr. A file with no firstmate
# turn-end signature - a settings.local.json the captain wrote, say - is left
# untouched, and so is this task's own hook.
fm_turnend_clear_foreign() {  # <worktree> <this-task-id>
  local wt=$1 mine=$2 rel owner
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    owner=$(fm_turnend_artifact_task_id "$wt/$rel")
    [ -n "$owner" ] || continue
    [ "$owner" != "$mine" ] || continue
    rm -f "$wt/$rel"
    echo "removed a stale turn-end hook ($rel) left in $wt by a previous occupant, for task '$owner'" >&2
  done <<< "$FM_TURNEND_ARTIFACTS"
}
