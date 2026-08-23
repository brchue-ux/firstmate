#!/usr/bin/env bash
# fm-treehouse-spelling-lib.sh - single owner of translating a resolved real
# worktree/home path into the spelling the `treehouse` CLI's own pool registry
# recognizes, for the boundary where firstmate hands a path to that CLI.
#
# Why this exists
# ----------------
# bin/fm-spawn.sh records every worktree path in physical (symlink-resolved)
# form via `pwd -P`, because that resolved form is what the worktree-isolation
# assertions in bin/fm-spawn.sh (and every generated ship brief) must compare:
# two different spellings of the same directory have to compare equal there,
# so weakening that resolution would be a real regression, not a fix.
#
# `treehouse` itself matches a worktree against its pool registry on the
# literal path string it leased it under, reached through $HOME/.treehouse (or
# TREEHOUSE_ROOT when set), and does not resolve symlinks. When $HOME/.treehouse
# is itself a symlink - for example, to a bind-mounted data volume - the
# physical spelling firstmate recorded and the literal spelling treehouse
# recognizes name the same real directory but differ as strings, and
# `treehouse return --force <physical-path>` refuses with "not managed by
# treehouse" even though the lease is live and correctly tracked. Before the
# symlink existed both spellings were byte-identical and this could not happen.
#
# fm_treehouse_recognized_path maps a resolved real path back to the spelling
# treehouse's registry expects. It is derived entirely from $HOME (or
# TREEHOUSE_ROOT) and the live filesystem - never a hardcoded user, machine, or
# pool name - so it works for any home reached through any symlink. It is a
# no-op (echoes the input unchanged) whenever the treehouse root is not itself
# a symlink, so a home with no symlink in play sees no behavior change. Every
# candidate spelling is verified by re-resolving it and confirming it names the
# same real directory before it is trusted; when that cannot be established, it
# fails closed - prints nothing, returns non-zero - so a caller can refuse
# rather than risk handing `treehouse` a spelling that might resolve to the
# wrong place.
#
# Usage, at a boundary that is about to invoke the `treehouse` CLI with a path:
#   # shellcheck source=bin/fm-treehouse-spelling-lib.sh
#   . "$SCRIPT_DIR/fm-treehouse-spelling-lib.sh"
#   spelled=$(fm_treehouse_recognized_path "$physical_path") || {
#     echo "error: cannot establish a treehouse-recognized spelling for $physical_path" >&2
#     exit 1
#   }
#   treehouse return --force "$spelled"

if [ -n "${FM_TREEHOUSE_SPELLING_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TREEHOUSE_SPELLING_LIB_SOURCED=1

# Physical (symlink-resolved) path of $1, or empty when it does not resolve to
# an existing directory.
fm_treehouse_physical_dir() {  # <dir>
  [ -n "${1:-}" ] || return 0
  (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || true
}

# Map a resolved real directory path to the spelling `treehouse` recognizes in
# its pool registry. Prints the spelling on success and returns 0.
#   - No-op (echoes $1 unchanged) when the treehouse root cannot be resolved at
#     all, or is not itself a symlink, or $1 does not lie under it: none of
#     those involve the divergence this helper exists to fix.
#   - Fails closed (prints nothing, returns 1) when a translation is indicated
#     but the resulting candidate cannot be verified to name the same real
#     directory as $1 - never guesses.
fm_treehouse_recognized_path() {  # <resolved-real-path>
  local real=${1:-} root_literal root_physical suffix candidate candidate_physical
  [ -n "$real" ] || return 1

  root_literal=${TREEHOUSE_ROOT:-$HOME/.treehouse}
  root_physical=$(fm_treehouse_physical_dir "$root_literal")

  if [ -z "$root_physical" ] || [ "$root_physical" = "$root_literal" ]; then
    printf '%s\n' "$real"
    return 0
  fi

  case $real in
    "$root_physical"/*)
      suffix=${real#"$root_physical"/}
      candidate="$root_literal/$suffix"
      ;;
    "$root_physical")
      candidate=$root_literal
      ;;
    *)
      printf '%s\n' "$real"
      return 0
      ;;
  esac

  candidate_physical=$(fm_treehouse_physical_dir "$candidate")
  if [ -n "$candidate_physical" ] && [ "$candidate_physical" = "$real" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}
