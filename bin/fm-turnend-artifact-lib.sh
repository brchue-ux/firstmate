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
# they touch, so the id reads straight off that path.
#
# The grok and kimi files are not hooks at all: they are one-line pointers
# holding `token=<basename of the mktemp authorization file>` (bin/fm-spawn.sh),
# and that basename is deliberately opaque - `fm.` plus twelve random
# characters - so it carries no task identity of its own. The identity lives in
# the authorization file the token names, under the harness's own global hooks
# dir, which holds the absolute state/<id>.turn-ended path. Resolving the token
# through that file is what ties the pointer back to a real task, and it is the
# same link the global Stop hook itself follows, so the sweep and the hook agree
# on what a pointer means.
#
# A pointer whose token is malformed, or whose authorization file is gone or
# does not hold a turn-ended path, is left UNATTRIBUTED on purpose: that is a
# pointer this cannot tie to any task, and the library never removes a file it
# cannot prove belongs to somebody else.
fm_turnend_artifact_task_id() {  # <file>
  local file=$1 token auth_dir target
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  case "$file" in
    *.fm-grok-turnend|*.fm-kimi-turnend)
      case "$file" in
        *.fm-grok-turnend) auth_dir="${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d" ;;
        *) auth_dir="$HOME/.kimi-code/fm-turn-end.d" ;;
      esac
      token=$(sed -n 's/^token=//p' "$file" | head -1)
      token=${token%%[[:space:]]*}
      # The same two-step token check the global hook applies before it resolves
      # one: the fixed mktemp shape, then a character allowlist so no token can
      # walk out of its authorization dir.
      case "$token" in
        fm.????????????) : ;;
        *) return 0 ;;
      esac
      case "$token" in *[!A-Za-z0-9._-]*) return 0 ;; esac
      target=$(cat "$auth_dir/$token" 2>/dev/null) || return 0
      case "$target" in
        /*.turn-ended) : ;;
        *) return 0 ;;
      esac
      target=${target##*/}
      printf '%s\n' "${target%.turn-ended}"
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
