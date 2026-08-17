#!/usr/bin/env bash
# Publish the durable `owner=<this home's herdr workspace label>` token onto a
# SECONDMATE's herdr workspace, but ONLY when that secondmate's home is a
# STANDALONE CLONE rather than a linked worktree of the primary's repo, so
# herdr's spaces sidebar can render that secondmate under the primary instead
# of as a second root beside it.
#
# Why only the standalone case. Herdr groups spaces by the repository a
# checkout belongs to, keyed on that checkout's canonicalized git COMMON dir.
# A secondmate home that is a linked worktree of this same firstmate repo
# therefore already shares the primary's key, and herdr nests it with no help
# from firstmate at all - that parentage is free, is the normal case
# (bin/fm-home-seed.sh seeds homes through treehouse), and this script
# deliberately never touches it: a linked-worktree home is a silent no-op with
# no herdr call of any kind. A home created as its OWN clone (fm-home-seed.sh's
# `git clone` fallback, used when treehouse is unavailable) has its own git
# dir, so herdr sees an unrelated repository and has no parentage signal to
# derive. The `owner` token is that missing signal. Publishing it is purely
# additive - it never removes, clears, or rewrites anything herdr derived
# itself.
#
# The linked-worktree test below is derived INDEPENDENTLY from git's own
# plumbing - a checkout is a linked worktree exactly when its git dir and its
# git common dir differ - rather than importing any herdr concept or code. That
# is the same distinction herdr's own `is_linked_worktree` field expresses, so
# the two agree on every checkout, while the derivation here stays firstmate's
# own and remains correct if herdr's internals change shape.
#
# NO --ttl-ms, deliberately, and this is the load-bearing durability decision.
# Every other durable herdr metadata publish in this repo
# (fm-herdr-outcome-publish.sh, fm-quality-event.sh, fm-quota-publish.sh) also
# omits it, and herdr's own contract for the omitted flag is "a token that
# never expires" (`herdr workspace report-metadata --help`, client 0.8.0), kept
# in herdr's persisted session state rather than only in memory. That is
# exactly right for this value. Unlike a sampled reading such as a context
# percentage, "which home owns this workspace" is a structural fact of the home
# that cannot go stale while the workspace exists, so an expiry protects
# against nothing here - while an expiring token would silently un-nest any
# secondmate left idle longer than its TTL, because an idle home publishes
# nothing and nothing would republish for it. A capped TTL is the right answer
# for the external statusline publisher, which republishes a moving value on
# every render; it is the wrong answer for this one. Spawn and every respawn
# publish it again regardless, so the value also re-converges on its own
# whenever the secondmate is relaunched.
#
# The workspace targeted is resolved ONLY from the task's own
# state/<task-id>.meta (kind=, backend=, herdr_session=, herdr_workspace_id=,
# home=, all written by fm-spawn.sh) - never a second identity scheme.
#
# This is a decoration, never a blocker: every unresolvable target (no task
# meta, a task that is not a secondmate, a non-herdr task, no recorded herdr
# session/workspace/home, an undecidable checkout, the herdr or jq tools
# missing, the CLI call itself failing) is a silent no-op that exits 0.
# Callers may still append `|| true` for defense in depth, but this script
# never needs it to stay non-blocking on its own.
#
# A malformed call (wrong argument count, an unsafe task id) is the one case
# treated as a caller bug: it prints a usage error and exits 2, so a broken
# call site is caught in testing rather than silently swallowed forever.
#
# Usage: fm-herdr-owner-publish.sh <task-id>
#   <task-id>  a kind=secondmate task recorded in this home's state dir
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# FM_HOME resolution: see bin/fm-home-anchor-lib.sh ("Why this exists").
# shellcheck source=bin/fm-home-anchor-lib.sh
. "$SCRIPT_DIR/fm-home-anchor-lib.sh"
fm_home_anchor_resolve "$FM_ROOT" >/dev/null 2>&1 || exit 0
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

fm_herdr_owner_publish_usage() {
  echo "usage: fm-herdr-owner-publish.sh <task-id>" >&2
}

if [ "$#" -ne 1 ]; then
  fm_herdr_owner_publish_usage
  exit 2
fi
ID=$1
if ! fm_task_id_path_safe "$ID"; then
  fm_herdr_owner_publish_usage
  exit 2
fi

# checkout_linked_worktree_state: classify <dir> the way git itself does, with
# three genuinely different answers rather than a boolean, because "I could not
# tell" must never be collapsed into either verdict:
#   linked      - a linked worktree: git dir and git common dir differ, so this
#                 checkout shares another checkout's repository and herdr can
#                 already derive its parentage. Never tagged.
#   standalone  - its own repository (git dir and git common dir are the same
#                 canonical path), or git positively answered that this is not
#                 a repository at all. Either way there is no shared-repository
#                 signal for herdr to group on, which is exactly the gap this
#                 script fills. Tagged.
#   undecidable - git is missing, git declined to answer at all (dubious
#                 ownership, an unreadable or unsupported repository, any other
#                 tool-level refusal), or git answered but its reported paths
#                 cannot be resolved on disk. Never tagged: leaving the sidebar
#                 as it is today is always safe, whereas tagging a checkout
#                 that might be a linked worktree would disturb the
#                 free-parentage path that already works.
#
# Note the asymmetry between the last two: a non-zero `git rev-parse` is NOT by
# itself evidence of anything, because git exits 128 both for "there is no
# repository here" (an answer this script acts on) and for "there is one and I
# refuse to look at it" (no answer at all). Only the message git prints tells
# them apart, so the probe below reads git's stderr rather than its status.
checkout_linked_worktree_state() {  # <dir>
  local dir=$1 probe rc git_dir common_dir abs_git_dir abs_common_dir
  command -v git >/dev/null 2>&1 || { printf 'undecidable'; return 0; }
  [ -d "$dir" ] || { printf 'undecidable'; return 0; }
  # Ask git a positive question first and keep what it says on failure. LC_ALL=C
  # pins the message to git's untranslated wording so the two failure meanings
  # stay distinguishable under any locale (gettext ignores LANGUAGE under C).
  probe=$(LC_ALL=C git -C "$dir" rev-parse --is-inside-work-tree 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    case $probe in
      *'not a git repository'*|*'not a working tree'*) printf 'standalone'; return 0 ;;
      *) printf 'undecidable'; return 0 ;;
    esac
  fi
  # From here git has proved it can read this checkout, so any further failure
  # is an anomaly rather than an answer.
  git_dir=$(git -C "$dir" rev-parse --git-dir 2>/dev/null) || { printf 'undecidable'; return 0; }
  # --git-common-dir predates every git this repo supports (2.5+) and is the
  # only field that distinguishes a linked worktree; if it is unavailable or
  # empty the classification is not merely unknown, it is unmade.
  common_dir=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || { printf 'undecidable'; return 0; }
  [ -n "$git_dir" ] && [ -n "$common_dir" ] || { printf 'undecidable'; return 0; }
  # Both values may be printed relative to <dir>; canonicalize each through the
  # filesystem so a relative ".git" and an absolute "/.../.git" for the same
  # directory compare equal rather than differing as strings. Every cd is
  # silenced and CDPATH-proofed: this script is a silent no-op on every
  # classification path, and a set CDPATH must never echo a search hit into the
  # captured path.
  abs_git_dir=$(CDPATH='' cd -- "$dir" 2>/dev/null && CDPATH='' cd -- "$git_dir" 2>/dev/null && pwd -P) || { printf 'undecidable'; return 0; }
  abs_common_dir=$(CDPATH='' cd -- "$dir" 2>/dev/null && CDPATH='' cd -- "$common_dir" 2>/dev/null && pwd -P) || { printf 'undecidable'; return 0; }
  [ -n "$abs_git_dir" ] && [ -n "$abs_common_dir" ] || { printf 'undecidable'; return 0; }
  if [ "$abs_git_dir" = "$abs_common_dir" ]; then
    printf 'standalone'
  else
    printf 'linked'
  fi
}

# Everything below is target resolution and the CLI call itself: any failure
# here is a decoration dropped, never a caller-visible error.
META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || exit 0

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

KIND=$(fm_backend_meta_exact_value "$META" kind) || exit 0
[ "$KIND" = secondmate ] || exit 0

[ "$(grep -c '^backend=' "$META" 2>/dev/null || true)" = 1 ] || exit 0
BACKEND=$(fm_backend_meta_exact_value "$META" backend) || exit 0
[ "$BACKEND" = herdr ] || exit 0

SESSION=$(fm_backend_meta_exact_value "$META" herdr_session) || exit 0
WORKSPACE=$(fm_backend_meta_exact_value "$META" herdr_workspace_id) || exit 0
HOME_PATH=$(fm_backend_meta_exact_value "$META" home) || exit 0

[ "$(checkout_linked_worktree_state "$HOME_PATH")" = standalone ] || exit 0

fm_backend_source herdr >/dev/null 2>&1 || exit 0
fm_backend_herdr_tool_check >/dev/null 2>&1 || exit 0

# The owner value is THIS home's own herdr workspace label, read through the
# one owner of that label scheme (fm_backend_herdr_workspace_label, from
# $FM_HOME) rather than hard-coding the string "firstmate": whichever home is
# running this spawn is the parent whose space the secondmate belongs under.
OWNER=$(fm_backend_herdr_workspace_label)
[ -n "$OWNER" ] || exit 0

# The workspace_id positional must precede the options for this herdr CLI
# version (verified live against 0.8.0): trailing it after --token errors
# "unknown option: <workspace_id>" rather than parsing it as the positional.
fm_backend_herdr_cli "$SESSION" workspace report-metadata "$WORKSPACE" \
  --source firstmate \
  --token "owner=$OWNER" \
  >/dev/null 2>&1 || true

exit 0
