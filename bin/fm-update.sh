#!/usr/bin/env bash
# Self-update a running firstmate and its secondmates to the latest origin.
#
# Mechanical half of the /updatefirstmate skill. Fast-forwards the running
# firstmate repo's default branch from origin, then fast-forwards every
# registered secondmate home (each a treehouse worktree of this same repo, or
# a standalone clone) the same way. FAST-FORWARD ONLY, exactly like
# fm-fleet-sync.sh: never force, never create a merge commit, never stash;
# advance a target only when it is a clean fast-forward, otherwise skip and
# report. A tracked-files fast-forward never touches the gitignored operational
# dirs (data/, state/, config/, projects/, .no-mistakes/), so a secondmate's
# in-flight work is never disrupted. Worktrees of this repo share one object
# store, so a single fetch refreshes them all; standalone-clone homes are
# fetched on their own.
#
# EVERY pooled firstmate home - the running firstmate itself included, not just
# its secondmates - is a treehouse worktree leased at a detached HEAD on the
# default branch (git refuses to let the same branch be checked out in more
# than one worktree, and `main` is normally held by the canonical clone). A
# clean, strictly-behind detached HEAD is therefore the routine, self-updatable
# shape, not an anomaly: it is advanced to the fetched default-branch tip in
# place, staying detached - never checked out to `main`, never given a branch
# of its own. A target genuinely checked out on the default branch (the
# canonical clone) fast-forwards that branch ref directly, the same as always.
# Either way the advance never touches any other worktree's checkout or the
# shared `main` branch. Dirty, diverged, a real non-default branch, or an
# offline fetch are still skipped and reported - see bin/fm-ff-lib.sh's
# ff_target for the exact guards.
#
# The fast-forward mechanics live in bin/fm-ff-lib.sh (base_mode "origin" here);
# the same library drives the local-HEAD secondmate sync used by fm-spawn.sh and
# fm-bootstrap.sh, so there is one ff implementation, not several.
#
# It does NOT re-read AGENTS.md or nudge secondmates itself - those are LLM /
# tmux actions the skill performs. The script's job is the safe git mechanics
# plus a parseable summary telling the caller what to do next:
#   - one status line per target (updated/already current/skipped)
#   - reread-firstmate: yes|no    (did the running firstmate's instructions change)
#   - nudge-secondmates: fm-<id>...|none   (updated live secondmates to nudge)
#
# Usage: fm-update.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# FM_HOME resolution: see bin/fm-home-anchor-lib.sh ("Why this exists").
# shellcheck source=bin/fm-home-anchor-lib.sh
. "$SCRIPT_DIR/fm-home-anchor-lib.sh"
fm_home_anchor_resolve "$FM_ROOT" || exit 1
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SECONDMATES_MD="$FM_HOME/data/secondmates.md"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() { echo "usage: fm-update.sh [--help]" >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

# --- main firstmate repo ---------------------------------------------------

reread_firstmate="no"
# allow_detached=yes: a pooled home is leased at a detached HEAD (see header);
# ff_target advances it in place without checking out or branching main.
ff_target "$FM_ROOT" "firstmate" origin yes no
if [ "$FF_STATUS" = "updated" ] && [ -n "$FF_INSTR" ]; then
  reread_firstmate="yes"
fi

# --- secondmates -----------------------------------------------------------
# An updated live secondmate is nudged whenever it advanced (nudge_requires_instr
# is "no" here): /updatefirstmate's nudge is a gentle re-read steer, kept on the
# same condition it has always used.

FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""

# Live direct reports first: state/<id>.meta with kind=secondmate carries the
# authoritative home= path.
sweep_live_secondmate_metas "$STATE" origin no

# Registry backstop: a secondmate registered in data/secondmates.md but without
# a live meta (e.g. between restarts) is still its persistent on-disk home.
if [ -f "$SECONDMATES_MD" ]; then
  while IFS= read -r line; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    id=$(printf '%s\n' "$line" | sed -n 's/^- \([^ ][^ ]*\) - .*/\1/p')
    home=$(printf '%s\n' "$line" | sed -n 's/.*(home:[[:space:]]*\([^;]*\);.*/\1/p' | sed 's/[[:space:]]*$//')
    process_secondmate "$id" "$home" "" origin no
  done < "$SECONDMATES_MD"
fi

# --- caller action summary -------------------------------------------------

echo "reread-firstmate: $reread_firstmate"
echo "nudge-secondmates:${FF_NUDGE_WINDOWS:- none}"
