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
# This is the single owner of the "is this scratch directory safe to remove"
# decision. Both reap trigger points call it rather than reimplementing the
# checks: bin/fm-bootstrap.sh sweeps at session start, and bin/fm-test-run.sh
# sweeps at the start of a test run. Keeping one implementation is deliberate -
# two copies of a destructive predicate drift the moment only one is edited.
#
# Usage:
#   fm-tmp-sweep.sh [--age-hours <n> | --age-minutes <n>] [--root <dir>]
#                   [--timeout <seconds>] [--max <n>] [--protect-homes <list>]
#                   [--name-prefix <prefix>] [--dry-run] [--verbose]
#   fm-tmp-sweep.sh -h | --help
#
# A candidate is removed only when every one of these holds, checked in this
# order so the cheap filters run before the expensive ones:
#   - its name matches this repo's scratch convention, fm-<slug>.<6 mktemp chars>
#   - its name starts with --name-prefix, when one was given. This can only
#     narrow the set above, never widen it, so a caller wanting a shorter age
#     window for its own artifacts can scope that window to names only it
#     creates instead of applying it to everything in the shared root
#   - it is a real directory, not a symlink, and is owned by the current user
#   - it holds neither the current working directory nor FM_HOME
#   - the sweep has not yet examined --max candidates
#   - the sweep still has time budget left; once the budget trips, every
#     remaining candidate is counted and deferred without further probing
#   - nothing anywhere inside it has been modified within the age window
#   - it carries no firstmate-home evidence of its own: a .fm-secondmate-home
#     marker, or real home content under data/ (backlog.md, projects.md,
#     secondmates.md). Bare empty state/, data/ and config/ directories are a
#     common test-fixture shape and are NOT home evidence.
#   - it is not, and does not contain, a scratch root any discoverable home
#     records as a live task's tasktmp=, and it carries no per-task gotmp/
#     marker. A task id is normally not mktemp-shaped so it never reaches this
#     check, but a dotted task id can be, and deleting a live task's scratch
#     corrupts running work.
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
#                                   be checked, time budget exhausted, the
#                                   --max candidate cap reached)
# Healthy skips - young, in use, not ours, not matching - stay silent unless
# --verbose is passed.
#
# Exit status:
#   0  the sweep ran; individual candidates may still have been skipped
#   1  the arguments were invalid
#   3  the sweep refused as a whole before examining anything, because a home's
#      records could not be read and a live task's scratch therefore could not
#      be ruled out. The message names which records - task records under
#      state/, or the home directory and secondmate registry that decide which
#      homes are read at all - so an operator inspects the right place. Callers
#      that report a completed sweep must not report one here.
#      bin/fm-bootstrap.sh ignores the status and classifies output.
#
# Environment overrides (defaults are the operating contract; these exist for
# tests and one-off manual runs, not as a configuration surface):
#   FM_TMP_SWEEP_AGE_HOURS   age window in hours (default 12)
#   FM_TMP_SWEEP_AGE_MINUTES age window in minutes; wins over the hours form.
#                            Exists for a caller that cannot express its window
#                            in whole hours; no caller shortens the default
#   FM_TMP_SWEEP_MAX         stop after examining this many candidates
#                            (default 0, meaning unbounded). A caller that
#                            wants a bound passes --max: session start must
#                            reclaim everything it can, so bounding it by
#                            default would strand orphans on the very host that
#                            leaked the most
#   FM_TMP_SWEEP_HOMES       extra firstmate homes to read task records from,
#                            colon-separated. FM_HOME and the secondmate homes
#                            each discoverable home registers are always read
#   FM_TMP_SWEEP_NAME_PREFIX consider only candidates whose name starts with
#                            this prefix (default none). Narrows the candidate
#                            set and never widens it
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
AGE_MINUTES_OPT=${FM_TMP_SWEEP_AGE_MINUTES:-}
ROOT_DIR=${FM_TMP_SWEEP_ROOT:-${TMPDIR:-/tmp}}
BUDGET=${FM_TMP_SWEEP_TIMEOUT:-20}
MAX=${FM_TMP_SWEEP_MAX:-0}
PROTECT_HOMES=${FM_TMP_SWEEP_HOMES:-}
NAME_PREFIX=${FM_TMP_SWEEP_NAME_PREFIX:-}
PROC_ROOT=${FM_TMP_SWEEP_PROC_ROOT:-/proc}
DRY_RUN=0
VERBOSE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --age-hours) [ $# -ge 2 ] || die "--age-hours needs a value"; AGE_HOURS=$2; AGE_MINUTES_OPT=; shift 2 ;;
    --age-minutes) [ $# -ge 2 ] || die "--age-minutes needs a value"; AGE_MINUTES_OPT=$2; shift 2 ;;
    --root) [ $# -ge 2 ] || die "--root needs a value"; ROOT_DIR=$2; shift 2 ;;
    --timeout) [ $# -ge 2 ] || die "--timeout needs a value"; BUDGET=$2; shift 2 ;;
    --max) [ $# -ge 2 ] || die "--max needs a value"; MAX=$2; shift 2 ;;
    --protect-homes) [ $# -ge 2 ] || die "--protect-homes needs a value"; PROTECT_HOMES=$2; shift 2 ;;
    --name-prefix)
      [ $# -ge 2 ] || die "--name-prefix needs a value"
      # An empty prefix would read as "scope this pass" while scoping nothing,
      # which is the one way this option could hand a caller a wider sweep than
      # it asked for. Absent means unscoped; present has to mean something.
      [ -n "$2" ] || die "name prefix must not be empty"
      NAME_PREFIX=$2
      shift 2
      ;;
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
case "$MAX" in
  ''|*[!0-9]*) die "max must be a non-negative integer, got '$MAX'" ;;
esac

# The minutes form wins when it is set, so a caller on a short horizon does not
# have to express itself in whole hours.
if [ -n "$AGE_MINUTES_OPT" ]; then
  case "$AGE_MINUTES_OPT" in
    ''|*[!0-9]*) die "age minutes must be a non-negative integer, got '$AGE_MINUTES_OPT'" ;;
  esac
  AGE_MINUTES=$AGE_MINUTES_OPT
  AGE_WINDOW="${AGE_MINUTES}m"
else
  AGE_MINUTES=$((AGE_HOURS * 60))
  AGE_WINDOW="${AGE_HOURS}h"
fi

[ -d "$ROOT_DIR" ] || exit 0

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

# --- live task scratch ------------------------------------------------------
#
# bin/fm-spawn.sh roots a task's scratch at "${FM_TASK_TMP_ROOT:-/tmp}/fm-<task
# id>" and records it as tasktmp= in state/<id>.meta. That name normally carries
# no mktemp suffix, so it never reaches the candidate list at all - but a task id
# ending in a dot plus six alphanumerics is shaped exactly like a fixture, and
# removing a live task's scratch corrupts work in flight. Reading the records is
# cheap next to the probes that follow, and it is the only check that can tell a
# live task's scratch from an abandoned fixture.

# Emitted by candidate_homes in place of a home it could not enumerate. The
# discovery walk runs inside a pipeline, so an exit status cannot reach the
# caller; the failure has to travel as a line. No real home path can collide
# with it.
HOME_SCAN_FAILED='!fm-tmp-sweep: a home registry could not be read'

# Bits protected_tasktmp sets, so the whole-sweep refusal can name where the
# operator should actually look. An unreadable state/<id>.meta and an
# unreadable home directory or secondmate registry are both fatal ambiguity,
# but they send an operator to different places.
AMBIGUOUS_TASK_RECORDS=1
AMBIGUOUS_HOME_RECORDS=2

# candidate_homes: the homes whose task records may name a live scratch root -
# this session's FM_HOME, every home named by --protect-homes, and every
# secondmate each of those registers.
candidate_homes() {
  local seeded home registry
  {
    [ -z "${FM_HOME:-}" ] || printf '%s\n' "$FM_HOME"
    if [ -n "$PROTECT_HOMES" ]; then
      printf '%s\n' "${PROTECT_HOMES//:/$'\n'}"
    fi
  } | LC_ALL=C sort -u | while IFS= read -r seeded; do
    [ -n "$seeded" ] || continue
    printf '%s\n' "$seeded"
    registry="$seeded/data/secondmates.md"
    # An unreadable registry hides a whole class of homes, so every live task
    # those homes record goes unseen - the same ambiguity as an unreadable task
    # record, and it must stop the sweep the same way. A registry that simply
    # is not there says the home has no secondmates, which is not ambiguous.
    # An unsearchable data/ is indistinguishable from a missing registry by
    # test alone, so it is checked first.
    if [ -d "$seeded/data" ] && [ ! -x "$seeded/data" ]; then
      printf '%s\n' "$HOME_SCAN_FAILED"
      continue
    fi
    if [ ! -r "$registry" ]; then
      if [ -e "$registry" ] || [ -L "$registry" ]; then
        printf '%s\n' "$HOME_SCAN_FAILED"
      fi
      continue
    fi
    while IFS= read -r home; do
      [ -n "$home" ] && printf '%s\n' "$home"
    done < <(sed -n 's/.*(home: *\([^;)]*\).*/\1/p' "$registry")
  done
}

# emit_protected_path <recorded>: a recorded tasktmp= value in every form a
# candidate could be compared against. Candidates are always ROOT_PHYS-prefixed,
# so a recorded path written through a symlinked temp root - /tmp on macOS -
# never matches verbatim and the protection would be inert. The recorded value
# is kept alongside the resolved one: a scratch root that has already gone means
# resolution fails, and dropping it there would silently unprotect it.
emit_protected_path() {
  local recorded=$1 phys
  [ -n "$recorded" ] || return 0
  printf '%s\n' "$recorded"
  phys=$(resolve_phys "$recorded") || return 0
  [ "$phys" = "$recorded" ] || printf '%s\n' "$phys"
}

# protected_tasktmp: every tasktmp= path those homes record. Fails when a home's
# records exist but cannot be read: an unreadable record is exactly the
# ambiguity that must stop the sweep rather than let it delete on a guess. The
# returned status carries which kind of record was unreadable.
protected_tasktmp() {
  local home meta recorded rc=0
  local -a metas
  while IFS= read -r home; do
    [ -n "$home" ] || continue
    if [ "$home" = "$HOME_SCAN_FAILED" ]; then
      rc=$((rc | AMBIGUOUS_HOME_RECORDS))
      continue
    fi
    # An unsearchable home root looks exactly like a home with no state/ from
    # the outside, so without this it would be skipped silently and every live
    # task it records would go unprotected.
    if [ -d "$home" ] && [ ! -x "$home" ]; then
      rc=$((rc | AMBIGUOUS_HOME_RECORDS))
      continue
    fi
    [ -d "$home/state" ] || continue
    if [ ! -r "$home/state" ] || [ ! -x "$home/state" ]; then
      rc=$((rc | AMBIGUOUS_TASK_RECORDS))
      continue
    fi
    metas=()
    for meta in "$home"/state/*.meta; do
      [ -f "$meta" ] || continue
      if [ ! -r "$meta" ]; then
        rc=$((rc | AMBIGUOUS_TASK_RECORDS))
        continue
      fi
      metas+=("$meta")
    done
    [ "${#metas[@]}" -eq 0 ] && continue
    while IFS= read -r recorded; do
      emit_protected_path "$recorded"
    done < <(sed -n 's/^tasktmp=//p' "${metas[@]}")
  done < <(candidate_homes | LC_ALL=C sort -u)
  return "$rc"
}

PROTECTED_PATHS=
AMBIGUITY=0
PROTECTED_PATHS=$(protected_tasktmp) || AMBIGUITY=$?
if [ "$AMBIGUITY" -ne 0 ]; then
  case "$AMBIGUITY" in
    "$AMBIGUOUS_TASK_RECORDS")
      AMBIGUITY_CAUSE="a firstmate home's task records could not be read" ;;
    "$AMBIGUOUS_HOME_RECORDS")
      AMBIGUITY_CAUSE="a firstmate home's directory or secondmate registry could not be read" ;;
    *)
      AMBIGUITY_CAUSE="a firstmate home's task records could not be read, and so could not another home's directory or secondmate registry" ;;
  esac
  report "$ROOT_DIR: skipped: $AMBIGUITY_CAUSE, so no scratch dir is safe to remove"
  exit 3
fi
PROTECTED_PATHS=$'\n'"$PROTECTED_PATHS"$'\n'

# is_live_task_scratch <dir>: true when <dir> is a recorded scratch root, sits
# inside one, or contains one. All three directions matter: the sweep must not
# remove a live scratch root, nor an ancestor that would take it with it.
#
# The walk is pure parameter expansion. A here-string or a pipe would make this
# check depend on a writable temp root, and it runs only for candidates that
# already cleared the age gate - which is to say on exactly the leaked or full
# root this sweep exists to drain. A failure there would fall through to "not
# live", the one direction that ends in a removal.
is_live_task_scratch() {
  local dir=$1 rest=${PROTECTED_PATHS#$'\n'} p
  case "$PROTECTED_PATHS" in
    *$'\n'"$dir"$'\n'*) return 0 ;;
  esac
  while [ -n "$rest" ]; do
    p=${rest%%$'\n'*}
    rest=${rest#*$'\n'}
    [ -n "$p" ] || continue
    case "$p" in
      "$dir"/*) return 0 ;;
    esac
    case "$dir" in
      "$p"/*) return 0 ;;
    esac
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
# Which of the two bounds stopped the examination. An operator reading the
# deferral line diagnoses a slow host and a capped run differently, so the two
# must never share a reason.
deferred_reason=

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
  # Applied after the convention check and quoted so the prefix is literal, so
  # it can only remove names from the set the convention already allowed.
  if [ -n "$NAME_PREFIX" ]; then
    case "$name" in
      "$NAME_PREFIX"*) ;;
      *) continue ;;
    esac
  fi
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

  # Both bounds are checked before the recursive age walk and the open-handle
  # probe, because those are the sweep's dominant costs; checking after them
  # would let a root full of large trees run far past the limits it claims to
  # honour.
  if [ "$MAX" -gt 0 ] && [ "$index" -gt "$MAX" ]; then
    deferred=$((total - index + 1))
    deferred_reason="the --max $MAX candidate cap was reached"
    break
  fi
  if [ "$SECONDS" -ge "$BUDGET" ]; then
    deferred=$((total - index + 1))
    deferred_reason="${BUDGET}s sweep budget exhausted"
    break
  fi

  # Nothing anywhere inside may have been touched within the age window. The
  # top-level mtime alone is not enough: a long test writes deep in its tree
  # without ever restamping the root it was handed.
  if [ -n "$(find "$entry" -mmin "-$AGE_MINUTES" -print 2>/dev/null | head -n 1)" ]; then
    note "$name: skipped: modified within $AGE_WINDOW"
    continue
  fi

  # After the age gate, so a live or young home is skipped silently and the
  # actionable line only fires for a directory that was otherwise about to be
  # removed.
  if looks_like_home "$entry"; then
    report "$name: skipped: looks like a firstmate home, not scratch"
    continue
  fi

  # A per-task scratch root carries a gotmp/ child; a recorded tasktmp= names it
  # outright. Either one means live work owns this directory.
  if [ -d "$entry/gotmp" ]; then
    report "$name: skipped: looks like a live task's scratch root, not a fixture"
    continue
  fi
  if is_live_task_scratch "$entry"; then
    report "$name: skipped: a firstmate home records it as a live task's scratch root"
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
  report "$ROOT_PHYS: skipped: $deferred_reason after removing $removed, $deferred candidate(s) deferred to the next session"
fi
exit 0
