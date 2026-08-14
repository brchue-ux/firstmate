#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, deterministic
# git identity and fixture builders, state/<id>.meta writers, and the common
# string/exit-code/file assertions. It deliberately does NOT bundle the
# behavior-specific fake tmux/treehouse/no-mistakes mocks: those encode terminal
# and lifecycle assumptions that differ per suite and belong with the tests that
# own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh) source this library for ROOT/fail/pass, and the test that
# includes them may also source it directly. Re-sourcing must not wipe the
# registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

# Declare this process tree to the FM_HOME resolver (bin/fm-home-anchor-lib.sh).
# Every fixture home in this suite is built by the test that then selects it, so
# an FM_HOME handed to a script here was always chosen, never inherited. Without
# this the suite would refuse whenever the checkout it runs from is itself a live
# firstmate home - which is exactly what the captain's primary home is. The
# declaration reaches only this tree, and bin/fm-spawn.sh blanks it on every
# launch line so it cannot follow a crewmate out of the suite.
export FM_HOME_BINDING=test-harness

# Hermetic browser state, for both readers of it at once. Left alone, the sweep
# (bin/fm-browser-sweep.sh) reads the developer's real chrome-devtools-axi root,
# so a browser session of their own left idle past the window would print a
# BROWSER_SWEEP line into every suite that asserts bootstrap silence, and
# bin/fm-teardown.sh would decide from that same real state whether a task's
# stop is worth invoking. Both go through bin/fm-browser-session-lib.sh, which
# owns where that state lives, so this one variable moves both; a suite that
# needs a real fixture root sets it there. Pointed at a path that cannot exist.
export FM_BROWSER_SESSION_ROOT=/nonexistent/fm-test-no-browser-state

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# --- temp roots -------------------------------------------------------------
#
# fm_test_tmproot <prefix> echoes a fresh temp dir under TMPDIR.
#
# bin/fm-test-run.sh is the single owner of fixture cleanup: it points TMPDIR at
# a private directory for each executed script and removes it when that script
# finishes, on an interrupted run as well as a normal one, and reaps fixtures
# orphaned by earlier killed runs. A test file therefore needs no EXIT trap of
# its own for its temp roots.
#
# The fm- prefix is still forced here rather than trusted to each caller, so a
# fixture that escapes the runner entirely - a direct `bash tests/<name>.test.sh`
# run killed outright - matches bin/fm-tmp-sweep.sh's session-start reclamation,
# which is the backstop for scratch the runner never saw.
#
# The registration below is only a convenience for a direct
# `bash tests/<name>.test.sh` run, and it takes effect only when the function is
# called in this shell: the common `root=$(fm_test_tmproot p)` form runs it in a
# command-substitution subshell, so the registered array never reaches the
# caller. A test file that needs extra teardown (e.g. killing a daemon) should
# define its own EXIT trap and call fm_test_cleanup from inside it.

FM_TEST_CLEANUP_DIRS=()

fm_test_cleanup() {
  local d
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}

fm_test_tmproot() {
  local prefix=${1:-fm-test} root
  case "$prefix" in
    fm-*) ;;
    *) prefix="fm-$prefix" ;;
  esac
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")
  if [ "${#FM_TEST_CLEANUP_DIRS[@]}" -eq 0 ]; then
    trap fm_test_cleanup EXIT
  fi
  FM_TEST_CLEANUP_DIRS+=("$root")
  printf '%s\n' "$root"
}

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# --- fixture processes ------------------------------------------------------
#
# fm_start_marked_process <dir> <basename> starts a real, running process whose
# ps command line carries <basename>, and echoes its pid. Callers that assert on
# process identity - the browser sweep and cleanup both read a recorded pid's
# argv - need a genuine process rather than a stub, and they distinguish
# processes only by that name, so one parameterized helper covers "a bridge",
# "a chrome-devtools-axi CLI call", and "something unrelated" alike.
#
# The caller owns killing what it starts; fm_kill_pids is the usual EXIT trap.

FM_TEST_STARTED_PIDS=()

fm_kill_pids() {
  local pid
  for pid in "${FM_TEST_STARTED_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  return 0
}

fm_start_marked_process() {
  local dir=$1 name=$2 script pid attempt=0
  mkdir -p "$dir"
  script="$dir/$name"
  printf '%s\n' '#!/usr/bin/env bash' 'sleep 300' > "$script"
  chmod +x "$script"
  # Detached from this function's stdout: it is read through a command
  # substitution, and a background child holding that pipe open would make the
  # caller wait for the child instead of for the pid.
  "$script" >/dev/null 2>&1 &
  pid=$!
  FM_TEST_STARTED_PIDS+=("$pid")
  # A backgrounded script still shows its PARENT's command line between fork and
  # exec, so anything reading argv in that window sees the wrong process - a
  # flake with nothing to do with the behavior under test.
  while [ "$attempt" -lt 200 ]; do
    case "$(ps -o args= -p "$pid" 2>/dev/null)" in
      *"$name"*) printf '%s\n' "$pid"; return 0 ;;
    esac
    sleep 0.05
    attempt=$((attempt + 1))
  done
  fail "fixture process $pid never showed '$name' in its command line"
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: init <repo> with one commit, then
# add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects] [harness]: write the
# standard kind=secondmate meta block used across the secondmate suites. Window
# defaults to firstmate:fm-<id>, projects defaults to alpha, and harness defaults
# to echo to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 id window projects=${4:-alpha} harness=${5:-echo}
  id=$(basename "$file" .meta)
  window=${3:-firstmate:fm-$id}
  fm_write_meta "$file" \
    "window=$window" \
    "endpoint_task_id=$id" \
    "worktree=$home" \
    "project=$home" \
    "harness=$harness" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# --- common assertions ------------------------------------------------------

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}

# --- partial bin/ fixtures --------------------------------------------------
#
# fm_copy_core_libs <dest-bin-dir> copies the libs that every bin/fm-*.sh needs
# before it can do anything at all, so a suite that assembles a partial bin/ from
# named scripts does not have to know that list. Suites that copy the whole bin/
# tree already have them.
FM_TEST_CORE_LIBS="fm-home-anchor-lib.sh fm-primary-scope-lib.sh"

fm_copy_core_libs() {
  local dest=$1 lib
  mkdir -p "$dest"
  for lib in $FM_TEST_CORE_LIBS; do
    cp "$ROOT/bin/$lib" "$dest/$lib"
  done
}
