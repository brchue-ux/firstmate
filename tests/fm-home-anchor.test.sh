#!/usr/bin/env bash
# Behavior tests for firstmate's FM_HOME resolution (bin/fm-home-anchor-lib.sh).
#
# FM_HOME is inherited down every launch line, so a session opened from another
# home's pane carries that home's FM_HOME with nothing in the environment able to
# say the selection was never meant for it. On 2026-07-31 that took a second
# mate's session lock and marked three of its tasks done from a session whose
# working directory was the primary home. These cases pin the resolution rule
# through a real executable that reveals WHICH home it read: fm-project-mode.sh
# prints the delivery mode recorded in $FM_HOME/data/projects.md, so a misroute
# shows up as the other home's mode rather than as a missing error message.
#
#   (a) primary cwd + inherited second mate FM_HOME  -> refuse, read neither
#   (b) second mate cwd + inherited primary FM_HOME  -> refuse, read neither
#   (c) second mate standing in its own home root    -> works
#   (d) crewmate in a pooled task worktree           -> FM_HOME stands
#   (e) worker inside <home>/projects/<name>         -> FM_HOME stands, no promotion
#   (f) FM_*_OVERRIDE layout control                 -> accepted as given
#   (g) FM_HOME_BINDING naming the same home         -> accepted as given
#   (h) FM_HOME_BINDING naming a different home      -> still refused
#   (i) FM_HOME unset                                -> the code root's own home
#   (j) FM_HOME that is not a home root              -> no rival claim, stands
#   (k) fm-send keeps its own fail-closed contract and gains the refusal
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE="$ROOT/bin/fm-project-mode.sh"
SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-home-anchor)
fm_git_identity fmtest fmtest@example.invalid

# A firstmate home root: a plain checkout carrying this home's own private
# material. <mate-id> makes it a second mate home by writing the identity marker
# bin/fm-home-seed.sh writes. <mode> is recorded for project "alpha" so the
# helper's output names the home that was actually read.
make_home() {  # <dir> <mode> [mate-id]
  local dir=$1 mode=$2 mate_id=${3:-}
  mkdir -p "$dir/bin" "$dir/data" "$dir/state" "$dir/config" "$dir/projects"
  printf '# home\n' > "$dir/AGENTS.md"
  printf -- '- alpha [%s] - fixture (added 2026-07-31)\n' "$mode" > "$dir/data/projects.md"
  git -C "$dir" init -q
  git -C "$dir" add -A >/dev/null 2>&1 || true
  git -C "$dir" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -qm home >/dev/null 2>&1 || true
  [ -z "$mate_id" ] || printf '%s\n' "$mate_id" > "$dir/.fm-secondmate-home"
}

# Run <cmd...> with cwd=<dir> and the given environment, capturing merged output.
# Echoes "<exit>|<output>" so a case can assert on both without a temp file.
run_in() {  # <dir> <cmd...>
  local dir=$1 out rc=0
  shift
  out=$( (cd "$dir" && "$@") 2>&1 ) || rc=$?
  printf '%s|%s' "$rc" "$out"
}

PRIMARY="$TMP_ROOT/primary"
MATE="$TMP_ROOT/mate"
make_home "$PRIMARY" no-mistakes
make_home "$MATE" local-only fitrpg

# ---------------------------------------------------------------------------
# (a) The reported defect: cwd is the primary home, FM_HOME was inherited from a
# second mate's pane. The command must not read the mate's registry.
# ---------------------------------------------------------------------------
res=$(run_in "$PRIMARY" env FM_HOME="$MATE" "$MODE" alpha)
rc=${res%%|*}
out=${res#*|}
expect_code 1 "$rc" "inherited mate FM_HOME from the primary home must refuse"
assert_not_contains "$out" "local-only" "refusal must not report the mate's delivery mode"
assert_contains "$out" "$PRIMARY" "diagnostic must name the home the command is running in"
assert_contains "$out" "$MATE" "diagnostic must name the FM_HOME candidate"
assert_contains "$out" "unset FM_HOME" "diagnostic must offer the local-home remedy"
assert_contains "$out" "FM_HOME_BINDING" "diagnostic must offer the deliberate cross-home remedy"
pass "primary cwd + inherited second mate FM_HOME refuses and names both homes"

# ---------------------------------------------------------------------------
# (b) The same misroute in the other direction, which the display-side fix on
# 2026-07-31 did not cover.
# ---------------------------------------------------------------------------
res=$(run_in "$MATE" env FM_HOME="$PRIMARY" "$MODE" alpha)
rc=${res%%|*}
out=${res#*|}
expect_code 1 "$rc" "inherited primary FM_HOME from a mate home must refuse"
assert_not_contains "$out" "no-mistakes" "refusal must not report the primary's delivery mode"
assert_contains "$out" "$MATE" "diagnostic must name the mate home it is running in"
assert_contains "$out" "$PRIMARY" "diagnostic must name the primary FM_HOME candidate"
pass "second mate cwd + inherited primary FM_HOME refuses and names both homes"

# ---------------------------------------------------------------------------
# (c) A second mate launched by fm-spawn with an explicit FM_HOME, standing in
# its own home root. This is agreement, not ambiguity.
# ---------------------------------------------------------------------------
res=$(run_in "$MATE" env FM_HOME="$MATE" "$MODE" alpha)
expect_code 0 "${res%%|*}" "a mate in its own home root must resolve"
assert_contains "${res#*|}" "local-only" "a mate in its own home root must read its own registry"
pass "second mate at its own home root with an explicit FM_HOME still works"

# A relative FM_HOME naming the same home is the same home, not a rival claim.
res=$(run_in "$MATE" env FM_HOME=. "$MODE" alpha)
expect_code 0 "${res%%|*}" "a relative FM_HOME naming the same home must resolve"
assert_contains "${res#*|}" "local-only" "relative FM_HOME must read the same home's registry"
pass "an unnormalized FM_HOME naming the same home is not treated as a conflict"

# ---------------------------------------------------------------------------
# (d) A crewmate in a pooled task worktree: cwd is a linked worktree of the same
# repo, with none of the home's private material. No anchor is available there,
# so the launching home's FM_HOME must stand.
# ---------------------------------------------------------------------------
WT_REPO="$TMP_ROOT/wt-repo"
WORKTREE="$TMP_ROOT/pool/task-1"
mkdir -p "$TMP_ROOT/pool"
fm_git_worktree "$WT_REPO" "$WORKTREE" fm/task-1
printf '# firstmate\n' > "$WORKTREE/AGENTS.md"
mkdir -p "$WORKTREE/bin"
res=$(run_in "$WORKTREE" env FM_HOME="$PRIMARY" "$MODE" alpha)
expect_code 0 "${res%%|*}" "a crewmate worktree must not be treated as a rival home"
assert_contains "${res#*|}" "no-mistakes" "a crewmate must read its launching home's registry"
pass "crewmate in a pooled task worktree keeps its launching home"

# Even a worktree that has accumulated state/ stays a worktree, never a home.
mkdir -p "$WORKTREE/state" "$WORKTREE/data"
res=$(run_in "$WORKTREE" env FM_HOME="$PRIMARY" "$MODE" alpha)
expect_code 0 "${res%%|*}" "a worktree with private dirs is still not a home"
assert_contains "${res#*|}" "no-mistakes" "worktree must still read its launching home"
pass "a task worktree is never promoted to a home, even carrying data/ and state/"

# ---------------------------------------------------------------------------
# (e) A worker inside a home's own projects/<name> clone. Containment must never
# resolve a home: this worker belongs to whichever home launched it.
# ---------------------------------------------------------------------------
CLONE="$MATE/projects/firstmate"
make_home "$CLONE" direct-PR
res=$(run_in "$CLONE" env FM_HOME="$MATE" "$MODE" alpha)
expect_code 0 "${res%%|*}" "a worker in a mate's project clone must not refuse"
assert_contains "${res#*|}" "local-only" "a worker in a clone must read the mate's registry"
pass "worker inside <home>/projects/<name> keeps the mate that launched it"

res=$(run_in "$CLONE" env FM_HOME="$PRIMARY" "$MODE" alpha)
expect_code 0 "${res%%|*}" "a clone under a mate must not promote a worker to that mate"
assert_contains "${res#*|}" "no-mistakes" "the launching home must still win inside a clone"
pass "a project clone never promotes a worker to the home containing it"

# ---------------------------------------------------------------------------
# (f) The layout overrides are explicit control and are accepted as given.
# ---------------------------------------------------------------------------
res=$(run_in "$PRIMARY" env FM_HOME="$MATE" FM_DATA_OVERRIDE="$MATE/data" "$MODE" alpha)
expect_code 0 "${res%%|*}" "an explicit data override must be accepted"
assert_contains "${res#*|}" "local-only" "an explicit override must select the named home"
pass "FM_DATA_OVERRIDE keeps working across homes"

res=$(run_in "$PRIMARY" env FM_HOME="$MATE" FM_ROOT_OVERRIDE="$ROOT" "$MODE" alpha)
expect_code 0 "${res%%|*}" "an explicit root override must be accepted"
assert_contains "${res#*|}" "local-only" "FM_ROOT_OVERRIDE must not re-anchor the home"
pass "FM_ROOT_OVERRIDE keeps working across homes"

# ---------------------------------------------------------------------------
# (g)/(h) The binding declares a deliberate cross-home selection, and names the
# home it was issued for so a stale one cannot bless a different FM_HOME.
# ---------------------------------------------------------------------------
res=$(run_in "$PRIMARY" env FM_HOME="$MATE" FM_HOME_BINDING="$MATE" "$MODE" alpha)
expect_code 0 "${res%%|*}" "a matching binding must be accepted"
assert_contains "${res#*|}" "local-only" "a matching binding must select the named home"
pass "a binding naming the same home confirms a deliberate cross-home command"

res=$(run_in "$PRIMARY" env FM_HOME="$MATE" FM_HOME_BINDING="$PRIMARY" "$MODE" alpha)
expect_code 1 "${res%%|*}" "a binding for another home must not bless this FM_HOME"
assert_not_contains "${res#*|}" "local-only" "a mismatched binding must not reach the mate"
pass "a binding naming a different home does not bless an inherited FM_HOME"

# ---------------------------------------------------------------------------
# (i) With FM_HOME unset there is nothing ambient to second-guess: the code root
# supplies the home, exactly as before.
# ---------------------------------------------------------------------------
res=$(run_in "$PRIMARY" env -u FM_HOME "$MODE" alpha)
expect_code 0 "${res%%|*}" "unset FM_HOME must resolve to the code root's home"
assert_contains "${res#*|}" "warn:" "the repo checkout has no fixture registry, so it must warn"
pass "an unset FM_HOME still resolves to the code root"

# ---------------------------------------------------------------------------
# (j) An FM_HOME that is not a home root is not a rival claim. This is what keeps
# fixture homes and temp paths in the rest of the suite working unchanged.
# ---------------------------------------------------------------------------
PLAIN="$TMP_ROOT/plain"
mkdir -p "$PLAIN/data" "$PLAIN/state"
printf -- '- alpha [direct-PR] - fixture (added 2026-07-31)\n' > "$PLAIN/data/projects.md"
res=$(run_in "$PRIMARY" env FM_HOME="$PLAIN" "$MODE" alpha)
expect_code 0 "${res%%|*}" "a non-home FM_HOME must not trigger the refusal"
assert_contains "${res#*|}" "direct-PR" "a non-home FM_HOME must still be honored"
pass "an FM_HOME that is not a home root raises no rival claim"

# ---------------------------------------------------------------------------
# (k) fm-send's own fail-closed contract is unchanged, and it now also refuses an
# ambiently inherited home rather than steering into another home's fleet.
# ---------------------------------------------------------------------------
res=$(run_in "$PRIMARY" env -u FM_HOME "$SEND" fm-nope hello)
expect_code 1 "${res%%|*}" "fm-send must still refuse without an explicit FM_HOME"
assert_contains "${res#*|}" "FM_HOME is not set" "fm-send must keep its own diagnostic"
pass "fm-send still refuses to resolve targets without an explicit home"

res=$(run_in "$PRIMARY" env FM_HOME="$MATE" "$SEND" fm-nope hello)
expect_code 1 "${res%%|*}" "fm-send must refuse an ambiently inherited home"
assert_contains "${res#*|}" "$MATE" "fm-send's refusal must name the inherited candidate"
pass "fm-send refuses to steer a fleet reached through an inherited home"
