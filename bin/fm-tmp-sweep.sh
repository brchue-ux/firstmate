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
# A candidate is removed only when every one of these holds, checked in this
# order so the cheap filters run before the expensive ones:
#   - its name matches this repo's scratch convention, fm-<slug>.<6 mktemp chars>
#   - it is a real directory, not a symlink, and is owned by the current user
#   - it holds neither the current working directory nor FM_HOME
#   - the sweep still has time budget left; once the budget trips, every
#     remaining candidate is counted and deferred without further probing
#   - nothing anywhere inside it has been modified within the age window
#   - it carries no firstmate-home evidence of its own: a .fm-secondmate-home
#     marker, or real home content under data/ (backlog.md, projects.md,
#     secondmates.md). Bare empty state/, data/ and config/ directories are a
#     common test-fixture shape and are NOT home evidence.
#   - no live process holds a path inside it open
# A candidate failing any of those is left exactly as it is; the sweep never
# forces, never follows symlinks out of the temp root, and never touches a path
# it did not enumerate itself. The sweep writes nothing at all outside the
# candidates it removes, so a full temp root cannot disable it.
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
#   FM_TMP_SWEEP_TIMEOUT     whole-sweep time budget in seconds (default 20);
#                            0 leaves no time for any candidate, so every one
#                            is deferred
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
# window, so this check is what protects it, not the mtime gate. It demands
# evidence only a real home carries - the seeded identity marker, or an actual
# home data file. The directory layout alone is not evidence: test fixtures
# routinely build a bare state/ + data/ + config/ triple in a scratch root, and
# exempting that shape would strand exactly the orphans this sweep exists for.
looks_like_home() {
  local dir=$1 rel
  if [ -e "$dir/.fm-secondmate-home" ] || [ -L "$dir/.fm-secondmate-home" ]; then
    return 0
  fi
  for rel in data/backlog.md data/projects.md data/secondmates.md; do
    if [ -e "$dir/$rel" ] || [ -L "$dir/$rel" ]; then
      return 0
    fi
  done
  return 1
}

# --- open-handle inventory --------------------------------------------------
#
# Built at most once per run, and only after a candidate has already cleared the
# age gate, so the usual sweep (no stale candidates) never pays for it. lsof is
# preferred because it is the one check that works on every supported host;
# procfs is the dependency-free Linux fallback. With neither available the sweep
# refuses to remove anything rather than guessing.
#
# The inventory is reduced, in the single probe pass, to the set of names
# directly under the swept root that some process holds open, and that set is
# held in memory. It is never spilled to a file: the outage this sweep exists to
# prevent is a full temp root, and a sweep that needed a writable temp root
# would disable itself precisely when it is needed. Keeping it as a name set
# also means each candidate costs one string test rather than a rescan.

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

IN_USE_NAMES=
IN_USE_BUILT=0
IN_USE_OK=1

TIMEOUT_CMD=
command -v timeout >/dev/null 2>&1 && TIMEOUT_CMD=timeout

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

# open_handle_probe: stream every open path the chosen checker can see, then one
# trailing status line so the reducer can tell a probe that was cut short from
# one that simply saw nothing. lsof gets -b so it can never block on a stale NFS
# or autofs mount, and the whole probe is held inside what is left of the sweep
# budget when a timeout command exists.
open_handle_probe() {
  local rc=0 left
  case "$CHECKER" in
    lsof)
      if [ -n "$TIMEOUT_CMD" ]; then
        left=$((BUDGET - SECONDS))
        [ "$left" -ge 1 ] || left=1
        "$TIMEOUT_CMD" "$left" lsof -b -n -P -w -F n 2>/dev/null | sed -n 's/^n//p'
      else
        lsof -b -n -P -w -F n 2>/dev/null | sed -n 's/^n//p'
      fi
      rc=${PIPESTATUS[0]}
      ;;
    proc) proc_open_paths || rc=$? ;;
  esac
  printf 'fm-tmp-sweep-probe-status %s\n' "$rc"
}

build_in_use_names() {
  [ "$IN_USE_BUILT" -eq 0 ] || return "$IN_USE_OK"
  IN_USE_BUILT=1
  local names rc
  # The root travels through the environment, not through awk -v, which would
  # interpret backslash escapes inside a path.
  names=$(open_handle_probe | FM_TMP_SWEEP_ROOT_PHYS="$ROOT_PHYS" awk '
    BEGIN { root = ENVIRON["FM_TMP_SWEEP_ROOT_PHYS"] "/"; rlen = length(root) }
    $1 == "fm-tmp-sweep-probe-status" { status = $2; next }
    { lines++ }
    index($0, root) != 1 { next }
    {
      rest = substr($0, rlen + 1)
      slash = index(rest, "/")
      if (slash > 0) rest = substr(rest, 1, slash - 1)
      if (rest == "" || (rest in seen)) next
      seen[rest] = 1
      print rest
    }
    # This process alone always holds open files, so an empty probe means the
    # check did not work rather than that the host is idle; a probe the timeout
    # cut short saw only part of the host. Either way, fail so the caller
    # reports instead of reading "nothing open" off an incomplete answer.
    END { exit (lines > 0 && status != 124 && status != 137) ? 0 : 1 }
  ')
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  IN_USE_NAMES=$'\n'"$names"$'\n'
  IN_USE_OK=0
  return 0
}

# dir_in_use <name>: true when any live process holds the candidate named <name>
# or a path below it open. Callers must have built the name set first; an
# unusable set counts as in use, so a failure here can only ever prevent a
# removal. Candidate names are constrained to the scratch convention, so they
# carry no character that could widen this match.
dir_in_use() {
  local name=$1
  [ "$IN_USE_OK" -eq 0 ] || return 0
  case "$IN_USE_NAMES" in
    *$'\n'"$name"$'\n'*) return 0 ;;
  esac
  return 1
}

# --- sweep ------------------------------------------------------------------

removed=0
unverified=0
deferred=0

# Pass one is the cheap pass: name, type, ownership and live-containment filters
# only, no syscall heavier than a stat. It exists so that when the time budget
# trips in pass two the sweep can count what it is deferring without paying a
# recursive walk per leftover candidate.
candidates=()
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
  candidates+=("$entry")
done

total=${#candidates[@]}
index=0
for entry in ${candidates[@]+"${candidates[@]}"}; do
  index=$((index + 1))
  name=${entry##*/}

  # Checked before the recursive age walk and the open-handle probe, because
  # those are the sweep's dominant costs; checking after them would let a root
  # full of large trees run far past the budget it claims to honour.
  if [ "$SECONDS" -ge "$BUDGET" ]; then
    deferred=$((total - index + 1))
    break
  fi

  # Nothing anywhere inside may have been touched within the age window. The
  # top-level mtime alone is not enough: a long test writes deep in its tree
  # without ever restamping the root it was handed.
  if [ -n "$(find "$entry" -mmin "-$AGE_MINUTES" -print 2>/dev/null | head -n 1)" ]; then
    note "$name: skipped: modified within ${AGE_HOURS}h"
    continue
  fi

  # After the age gate, so a live or young home is skipped silently and the
  # actionable line only fires for a directory that was otherwise about to be
  # removed.
  if looks_like_home "$entry"; then
    report "$name: skipped: looks like a firstmate home, not scratch"
    continue
  fi

  if [ "$CHECKER" != none ] && ! build_in_use_names; then
    CHECKER=none
  fi
  if [ "$CHECKER" = none ]; then
    unverified=$((unverified + 1))
    continue
  fi
  if dir_in_use "$name"; then
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
  report "$ROOT_PHYS: skipped: $unverified stale scratch dir(s) left in place: cannot verify open handles (needs lsof or a readable procfs)"
fi
if [ "$deferred" -gt 0 ]; then
  report "$ROOT_PHYS: skipped: ${BUDGET}s sweep budget exhausted after removing $removed, $deferred candidate(s) deferred to the next session"
fi
exit 0
