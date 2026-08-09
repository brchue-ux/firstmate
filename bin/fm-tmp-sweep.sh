#!/usr/bin/env bash
# fm-tmp-sweep.sh - reclaim stale orphaned firstmate scratch directories from
# the shared temp root.
#
# Why this exists: tests/lib.sh's fm_test_tmproot, a few test files that call
# mktemp directly, and several bin/ helpers all create scratch directories named
# "fm-<slug>.XXXXXX" under ${TMPDIR:-/tmp} and remove them from an EXIT trap. An
# EXIT trap never runs when the process is killed abruptly - a worktree or pane
# torn down mid-run, a kill -9 on a stuck test - so the directory is orphaned.
# Every firstmate home on a host shares one small temp filesystem, so a handful
# of orphaned fixture trees fills it and every home then fails silently on temp
# writes. This sweep is the backstop for that leak; making EXIT traps survive
# SIGKILL is a separate, much larger problem and is deliberately out of scope.
#
# Usage:
#   fm-tmp-sweep.sh [--age-hours <n>] [--root <dir>] [--timeout <seconds>]
#                   [--dry-run] [--verbose]
#   fm-tmp-sweep.sh -h | --help
#
# A candidate is removed only when every one of these holds:
#   - its name matches this repo's scratch convention, fm-<slug>.<6 mktemp chars>
#   - it is a real directory, not a symlink, and is owned by the current user
#   - it holds neither the current working directory nor FM_HOME, and carries no
#     firstmate-home marker of its own
#   - nothing anywhere inside it has been modified within the age window
#   - no live process holds a path inside it open
# A candidate failing any of those is left exactly as it is; the sweep never
# forces, never follows symlinks out of the temp root, and never touches a path
# it did not enumerate itself.
#
# Output is one line per notable outcome and silent otherwise, in the same
# "<subject>: <verb>: <detail>" shape the other session-start sweeps use:
#   "<name>: removed"
#   "<name>: skipped: <reason>"   - a stale candidate the sweep refused (it is
#                                   really an operational home) or failed to
#                                   remove
#   "<root>: skipped: <reason>"   - a whole-sweep limit (open handles could not
#                                   be checked, time budget exhausted)
# Healthy skips - young, in use, not ours, not matching - stay silent unless
# --verbose is passed. Exit status is 0 unless the arguments are invalid.
#
# Environment overrides (defaults are the operating contract; these exist for
# tests and one-off manual runs, not as a configuration surface):
#   FM_TMP_SWEEP_AGE_HOURS   age window in hours (default 12)
#   FM_TMP_SWEEP_ROOT        temp root to sweep (default ${TMPDIR:-/tmp})
#   FM_TMP_SWEEP_TIMEOUT     whole-sweep time budget in seconds (default 20)
#   FM_TMP_SWEEP_PROC_ROOT   procfs root for the open-handle fallback (/proc)
#   FM_TMP_SWEEP_CHECKER     pin the open-handle check: auto (default), lsof,
#                            proc, or none
set -u

SELF="${BASH_SOURCE[0]}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF" >&2
}

die() {
  printf 'fm-tmp-sweep.sh: %s\n' "$1" >&2
  exit 1
}

AGE_HOURS=${FM_TMP_SWEEP_AGE_HOURS:-12}
ROOT_DIR=${FM_TMP_SWEEP_ROOT:-${TMPDIR:-/tmp}}
BUDGET=${FM_TMP_SWEEP_TIMEOUT:-20}
PROC_ROOT=${FM_TMP_SWEEP_PROC_ROOT:-/proc}
DRY_RUN=0
VERBOSE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --age-hours) [ $# -ge 2 ] || die "--age-hours needs a value"; AGE_HOURS=$2; shift 2 ;;
    --root) [ $# -ge 2 ] || die "--root needs a value"; ROOT_DIR=$2; shift 2 ;;
    --timeout) [ $# -ge 2 ] || die "--timeout needs a value"; BUDGET=$2; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument '$1'" ;;
  esac
done

case "$AGE_HOURS" in
  ''|*[!0-9]*) die "age hours must be a non-negative integer, got '$AGE_HOURS'" ;;
esac
case "$BUDGET" in
  ''|*[!0-9]*) die "timeout must be a non-negative integer, got '$BUDGET'" ;;
esac
[ -d "$ROOT_DIR" ] || exit 0

AGE_MINUTES=$((AGE_HOURS * 60))

note() {
  [ "$VERBOSE" -eq 1 ] || return 0
  printf '%s\n' "$1"
}

report() {
  printf '%s\n' "$1"
}

# --- self-protection -------------------------------------------------------
#
# Resolve the two live locations that must never be swept even if their mtimes
# went cold: the shell's own working directory and this session's FM_HOME. Both
# are compared as resolved physical paths so a symlinked temp root cannot hide a
# containment match.

resolve_phys() {
  local p=$1
  [ -n "$p" ] || return 1
  [ -d "$p" ] || return 1
  (cd "$p" 2>/dev/null && pwd -P) || return 1
}

PWD_PHYS=$(resolve_phys "$PWD" || true)
HOME_PHYS=$(resolve_phys "${FM_HOME:-}" || true)
ROOT_PHYS=$(resolve_phys "$ROOT_DIR") || exit 0

# path_contains <ancestor> <path>: true when <path> is <ancestor> or below it.
path_contains() {
  local ancestor=$1 path=$2
  [ -n "$path" ] || return 1
  case "$path" in
    "$ancestor"|"$ancestor"/*) return 0 ;;
  esac
  return 1
}

# looks_like_home <dir>: a firstmate operational home must never be mistaken for
# scratch. An idle secondmate home can sit unwritten for longer than the age
# window, so this check is what protects it, not the mtime gate.
looks_like_home() {
  local dir=$1
  if [ -e "$dir/.fm-secondmate-home" ] || [ -L "$dir/.fm-secondmate-home" ]; then
    return 0
  fi
  if [ -d "$dir/state" ] && [ -d "$dir/data" ] && [ -d "$dir/config" ]; then
    return 0
  fi
  return 1
}

# --- open-handle inventory --------------------------------------------------
#
# Built at most once per run, and only after a candidate has already cleared the
# age gate, so the usual sweep (no stale candidates) never pays for it. lsof is
# preferred because it is the one check that works on every supported host;
# procfs is the dependency-free Linux fallback. With neither available the sweep
# refuses to remove anything rather than guessing.

CHECKER=${FM_TMP_SWEEP_CHECKER:-auto}
case "$CHECKER" in
  auto)
    if command -v lsof >/dev/null 2>&1; then
      CHECKER=lsof
    elif [ -d "$PROC_ROOT" ] && [ -r "$PROC_ROOT" ]; then
      CHECKER=proc
    else
      CHECKER=none
    fi
    ;;
  lsof|proc|none) ;;
  *) die "open-handle check must be auto, lsof, proc, or none, got '$CHECKER'" ;;
esac

IN_USE_LIST=
IN_USE_BUILT=0

proc_open_paths() {
  local pid link target
  for pid in "$PROC_ROOT"/[0-9]*; do
    [ -d "$pid" ] || continue
    for link in "$pid/cwd" "$pid/fd"/*; do
      target=$(readlink "$link" 2>/dev/null) || continue
      [ -n "$target" ] && printf '%s\n' "$target"
    done
  done
}

build_in_use_list() {
  [ "$IN_USE_BUILT" -eq 0 ] || return 0
  IN_USE_BUILT=1
  IN_USE_LIST=$(mktemp "$ROOT_PHYS/.fm-tmp-sweep.XXXXXX" 2>/dev/null) || {
    IN_USE_LIST=
    return 1
  }
  case "$CHECKER" in
    lsof) lsof -n -P -w -F n 2>/dev/null | sed -n 's/^n//p' >"$IN_USE_LIST" ;;
    proc) proc_open_paths >"$IN_USE_LIST" ;;
  esac
  # This process alone always holds open files, so an empty inventory means the
  # check did not work rather than that the host is idle. Treat it as a failure
  # so the caller reports instead of reading "nothing open" off a broken probe.
  [ -s "$IN_USE_LIST" ]
}

# dir_in_use <dir>: true when any live process holds <dir> or a path below it.
# Callers must have built the inventory first; a missing inventory counts as in
# use, so a failure here can only ever prevent a removal.
dir_in_use() {
  local dir=$1
  [ -n "$IN_USE_LIST" ] || return 0
  # The candidate path travels through the environment, not through awk -v,
  # which would interpret backslash escapes inside a path.
  FM_TMP_SWEEP_CANDIDATE="$dir" awk '
    BEGIN { self = ENVIRON["FM_TMP_SWEEP_CANDIDATE"]; below = self "/" }
    index($0, below) == 1 { found = 1; exit }
    $0 == self { found = 1; exit }
    END { exit !found }
  ' "$IN_USE_LIST"
}

# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
cleanup() {
  [ -n "$IN_USE_LIST" ] && rm -f "$IN_USE_LIST"
  return 0
}
trap cleanup EXIT

# --- sweep ------------------------------------------------------------------

removed=0
unverified=0
deferred=0
budget_hit=0

for entry in "$ROOT_PHYS"/fm-*.??????; do
  [ -e "$entry" ] || continue
  name=${entry##*/}
  # The mktemp template every scratch site uses is fm-<slug>.XXXXXX, so the
  # suffix is exactly six alphanumerics. Matching the convention rather than a
  # list of today's prefixes keeps new test files covered with no edit here.
  [[ $name =~ ^fm-[A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z0-9]{6}$ ]] || continue
  [ -L "$entry" ] && continue
  [ -d "$entry" ] || continue
  [ -O "$entry" ] || { note "$name: skipped: owned by another user"; continue; }

  if path_contains "$entry" "$PWD_PHYS" || path_contains "$entry" "$HOME_PHYS"; then
    note "$name: skipped: holds a live working directory or home"
    continue
  fi
  if looks_like_home "$entry"; then
    report "$name: skipped: looks like a firstmate home, not scratch"
    continue
  fi

  # Nothing anywhere inside may have been touched within the age window. The
  # top-level mtime alone is not enough: a long test writes deep in its tree
  # without ever restamping the root it was handed.
  if [ -n "$(find "$entry" -mmin "-$AGE_MINUTES" -print 2>/dev/null | head -n 1)" ]; then
    note "$name: skipped: modified within ${AGE_HOURS}h"
    continue
  fi

  if [ "$budget_hit" -eq 1 ]; then
    deferred=$((deferred + 1))
    continue
  fi
  if [ "$BUDGET" -gt 0 ] && [ "$SECONDS" -ge "$BUDGET" ]; then
    budget_hit=1
    deferred=$((deferred + 1))
    continue
  fi

  if [ "$CHECKER" != none ] && ! build_in_use_list; then
    CHECKER=none
  fi
  if [ "$CHECKER" = none ]; then
    unverified=$((unverified + 1))
    continue
  fi
  if dir_in_use "$entry"; then
    note "$name: skipped: a live process holds it open"
    continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    report "$name: removed (dry run)"
    removed=$((removed + 1))
    continue
  fi
  if err=$(rm -rf -- "$entry" 2>&1) && [ ! -e "$entry" ]; then
    report "$name: removed"
    removed=$((removed + 1))
  else
    report "$name: skipped: removal failed: ${err%%$'\n'*}"
  fi
done

if [ "$unverified" -gt 0 ]; then
  report "$ROOT_PHYS: skipped: $unverified stale scratch dir(s) left in place: cannot verify open handles (needs lsof or a readable procfs, plus a writable temp root)"
fi
if [ "$deferred" -gt 0 ]; then
  report "$ROOT_PHYS: skipped: ${BUDGET}s sweep budget exhausted after removing $removed, $deferred candidate(s) deferred to the next session"
fi
exit 0
