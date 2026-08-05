#!/usr/bin/env bash
# fm-home-anchor-lib.sh - the single owner of firstmate's FM_HOME resolution.
# Sourced by every bin/fm-*.sh and bin/backends/*.sh that needs a home; it has
# no side effects on source.
#
# Why this exists
# ---------------
# FM_HOME is inherited down every launch line, so a session opened from another
# home's pane silently carries that home's FM_HOME. The variable alone cannot
# say whether it was handed to THIS process deliberately or merely inherited
# from an ancestor that had nothing to do with it, and no environment variable
# can: a child and a grandchild see byte-identical environments, so a launch
# token is inherited exactly as far as FM_HOME is.
#
# The one observable difference is on disk. When a process is standing IN a
# firstmate home root that is not the FM_HOME it was handed, two different homes
# are claiming the same command and nothing in the environment can say which is
# right. This resolver refuses that case with a diagnostic instead of guessing,
# because a silent misroute takes another home's session lock and edits another
# home's durable records.
#
# The contract
# ------------
#   1. FM_HOME unset          -> FM_ROOT_OVERRIDE, else the caller's code root.
#   2. EVERY home-material override set (FM_STATE_OVERRIDE, FM_DATA_OVERRIDE,
#      FM_PROJECTS_OVERRIDE, FM_CONFIG_OVERRIDE) -> FM_HOME no longer selects any
#      of this home's material, so there is nothing left for it to misroute and
#      it is accepted as given. A partial set is deliberately not enough: the
#      directories that were not overridden still come from FM_HOME, and a
#      caller that derives one override FROM an ambient FM_HOME would otherwise
#      launder that ambient value into a declaration. FM_ROOT_OVERRIDE never
#      counts on its own, because it relocates the code root, not the home.
#   3. FM_HOME_BINDING declares the selection deliberate, in one of two forms.
#      A PATH naming the same home as FM_HOME is the per-invocation form every
#      cross-home caller in bin/ uses; because it names the home it was issued
#      for, a stale inherited binding cannot bless a different FM_HOME. The
#      literal `test-harness` is the process-tree form, for a caller that
#      constructs and names every home it hands down - firstmate's own test
#      runner is the only such caller, since each fixture home is built by the
#      test that then selects it. bin/fm-spawn.sh blanks FM_HOME_BINDING on
#      every launch line, so neither form can reach an agent session by
#      inheritance.
#      Resolution READS a binding and never issues one. Nothing here is
#      exported, so a declaration covers the command tree its caller chose to
#      hand it to and no other: a long-lived process started from a home - the
#      multiplexer server bin/backends/tmux.sh and bin/backends/zellij.sh create,
#      whose every later pane inherits its environment - can only capture a
#      declaration that was deliberately handed to it.
#   4. Otherwise, when the working directory and FM_HOME are BOTH firstmate home
#      roots and are not the same home -> refuse, naming both candidates.
#   5. Otherwise FM_HOME stands.
#
# Rule 4 is deliberately narrow in both directions. The working directory must
# BE a home root, never merely be contained in one: crewmates legitimately run
# inside a home's projects/<name> clone and inside pooled task worktrees, and
# promoting either to that home would be its own misroute. FM_HOME must also be
# a real home root, so a temp path or a half-built fixture is never treated as a
# rival claim.
#
# Usage, after the caller has resolved its own FM_ROOT (the code root):
#   # shellcheck source=bin/fm-home-anchor-lib.sh
#   . "$SCRIPT_DIR/fm-home-anchor-lib.sh"
#   fm_home_anchor_resolve "$FM_ROOT" || exit 1
#
# Hooks that must never act on the wrong home, but must also never break a turn,
# pass `quiet` and treat a non-zero return as "do not act":
#   fm_home_anchor_resolve "$FM_ROOT" quiet || exit 0

if [ -n "${FM_HOME_ANCHOR_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_HOME_ANCHOR_LIB_SOURCED=1

FM_HOME_ANCHOR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# The secondmate-home marker predicate has one owner; reuse it rather than
# re-deriving what a valid marker looks like.
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$FM_HOME_ANCHOR_LIB_DIR/fm-primary-scope-lib.sh"

# Physical path of $1, or empty when it does not resolve to a directory.
fm_home_anchor_physical() {  # <dir>
  [ -n "${1:-}" ] || return 0
  (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || true
}

# Return 0 when $1 is provably a firstmate HOME root - not merely a firstmate
# code root, and never something that only lives inside one.
#
# Ordered so the cheapest rejection comes first: this runs inside per-turn hooks,
# and only the last test forks git.
fm_home_anchor_is_home_root() {  # <dir>
  local dir=${1:-} parent git_dir git_common
  [ -n "$dir" ] || return 1
  # Every home root is also a firstmate code root.
  [ -f "$dir/AGENTS.md" ] || return 1
  [ -d "$dir/bin" ] || return 1
  # A valid marker is definitive: only bin/fm-home-seed.sh writes one.
  if fm_root_is_secondmate_home "$dir"; then
    return 0
  fi
  # Otherwise a home must carry this home's own private material. Both dirs are
  # gitignored, so a pooled task worktree and a fresh clone have neither, and
  # this rejects them without forking git.
  [ -d "$dir/data" ] || [ -d "$dir/state" ] || return 1
  # A clone under some home's projects/ can accumulate those directories over
  # time; it is still that home's project, never a home of its own.
  parent=${dir%/*}
  if [ "${parent##*/}" = projects ] && [ -f "${parent%/*}/AGENTS.md" ]; then
    return 1
  fi
  # A linked worktree of a home is not that home.
  git_dir=$(git -C "$dir" rev-parse --git-dir 2>/dev/null) || return 1
  git_common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ "$git_dir" = "$git_common" ]
}

fm_home_anchor_refuse() {  # <cwd-home> <given> <given-physical>
  local cwd_home=$1 given=$2 given_phys=$3 shown=$2
  [ "$given_phys" = "$given" ] || shown="$given (resolves to $given_phys)"
  {
    echo "error: FM_HOME names a different firstmate home than the one this command is running in."
    echo "  running in: $cwd_home"
    echo "  FM_HOME:    $shown"
    echo "FM_HOME is inherited by every process launched from another home's session, so it cannot"
    echo "show by itself whether it was chosen for this command or carried in from an unrelated"
    echo "ancestor. Refusing rather than picking one, because guessing wrong takes the other home's"
    echo "session lock and writes to its durable records."
    echo "  to use the home you are standing in:   unset FM_HOME"
    echo "  to confirm the other home on purpose:  FM_HOME_BINDING=\"\$FM_HOME\" <command>"
  } >&2
}

# The process-tree declaration (contract rule 3). Kept as a constant so the one
# literal firstmate's test runner exports has exactly one spelling.
FM_HOME_ANCHOR_HARNESS_BINDING=test-harness

# Resolve FM_HOME for this process. Sets FM_HOME; returns non-zero only when
# resolution is genuinely ambiguous, after printing the diagnostic above unless
# the caller asked for `quiet`.
fm_home_anchor_resolve() {  # <default-root> [quiet]
  local default_root=${1:-} quiet=${2:-} given cwd home_phys bound

  if [ -z "${FM_HOME:-}" ]; then
    FM_HOME="${FM_ROOT_OVERRIDE:-$default_root}"
    return 0
  fi
  given=$FM_HOME

  if [ -n "${FM_STATE_OVERRIDE:-}" ] && [ -n "${FM_DATA_OVERRIDE:-}" ] &&
    [ -n "${FM_PROJECTS_OVERRIDE:-}" ] && [ -n "${FM_CONFIG_OVERRIDE:-}" ]; then
    return 0
  fi

  # Fork-free rejections before any path normalization.
  if [ "${PWD:-}" = "$given" ]; then
    return 0
  fi
  if ! fm_home_anchor_is_home_root "${PWD:-}" || ! fm_home_anchor_is_home_root "$given"; then
    return 0
  fi

  cwd=$(fm_home_anchor_physical "${PWD:-}")
  home_phys=$(fm_home_anchor_physical "$given")
  if [ -z "$cwd" ] || [ -z "$home_phys" ] || [ "$cwd" = "$home_phys" ]; then
    return 0
  fi

  if [ "${FM_HOME_BINDING:-}" = "$FM_HOME_ANCHOR_HARNESS_BINDING" ]; then
    return 0
  fi
  if [ -n "${FM_HOME_BINDING:-}" ]; then
    bound=$(fm_home_anchor_physical "$FM_HOME_BINDING")
    [ -n "$bound" ] || bound=$FM_HOME_BINDING
    if [ "$bound" = "$home_phys" ]; then
      return 0
    fi
  fi

  [ "$quiet" = quiet ] || fm_home_anchor_refuse "$cwd" "$given" "$home_phys"
  return 1
}
