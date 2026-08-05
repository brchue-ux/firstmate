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
#   (l) resolving a home issues no declaration of its own to descendants
#   (m) a second resolve in the same process settles the same way
#   (n) a resolution record from outside the process declares nothing
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# This suite is the one place that must see the resolver's real behavior, so it
# drops the process-tree declaration tests/lib.sh exports for every other suite.
# Cases that need a declaration set one explicitly.
unset FM_HOME_BINDING

MODE="$ROOT/bin/fm-project-mode.sh"
SEND="$ROOT/bin/fm-send.sh"
LOCK="$ROOT/bin/fm-lock.sh"
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
# (f) Relocating every one of this home's directories leaves FM_HOME selecting
# no material at all, so there is nothing left for it to misroute. This is the
# shape firstmate's own cross-home calls use.
# ---------------------------------------------------------------------------
res=$(run_in "$PRIMARY" env FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" \
  FM_DATA_OVERRIDE="$MATE/data" FM_PROJECTS_OVERRIDE="$MATE/projects" \
  FM_CONFIG_OVERRIDE="$MATE/config" "$MODE" alpha)
expect_code 0 "${res%%|*}" "a complete set of home-material overrides must be accepted"
assert_contains "${res#*|}" "local-only" "a complete override set must select the named home"
pass "a complete home-material override set keeps working across homes"

# A partial set is not a declaration: whatever was not overridden still comes
# from FM_HOME, so the ambiguity is real. This is the shape the Pi and OpenCode
# watcher-arm paths use - they derive FM_CONFIG_OVERRIDE from the ambient
# FM_HOME, which would otherwise launder that ambient value into a declaration.
res=$(run_in "$PRIMARY" env FM_HOME="$MATE" FM_DATA_OVERRIDE="$MATE/data" "$MODE" alpha)
expect_code 1 "${res%%|*}" "a partial override set must not declare an inherited home deliberate"
pass "a partial home-material override set does not wave an inherited home through"

res=$(run_in "$PRIMARY" env FM_HOME="$MATE" FM_ROOT_OVERRIDE="$ROOT" \
  FM_CONFIG_OVERRIDE="$MATE/config" "$MODE" alpha)
expect_code 1 "${res%%|*}" "the harness arm-path override shape must not bypass anchoring"
assert_not_contains "${res#*|}" "local-only" "the arm-path shape must not reach the mate"
pass "FM_ROOT_OVERRIDE plus a derived config override is not a declaration"

# FM_ROOT_OVERRIDE relocates the code root, not the home, so it never declares a
# home on its own - but it must still supply the home when FM_HOME is unset.
res=$(run_in "$PRIMARY" env -u FM_HOME FM_ROOT_OVERRIDE="$MATE" "$MODE" alpha)
expect_code 0 "${res%%|*}" "FM_ROOT_OVERRIDE must still stand in for an unset FM_HOME"
assert_contains "${res#*|}" "local-only" "FM_ROOT_OVERRIDE must supply the home when FM_HOME is unset"
pass "FM_ROOT_OVERRIDE still behaves as the whole-root override when FM_HOME is unset"

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

# The process-tree form covers a caller that builds every home it hands down, so
# nothing it passes can be ambient. This suite's own runner is that caller.
res=$(run_in "$PRIMARY" env FM_HOME="$MATE" FM_HOME_BINDING=test-harness "$MODE" alpha)
expect_code 0 "${res%%|*}" "the process-tree declaration must be accepted"
assert_contains "${res#*|}" "local-only" "the process-tree declaration must select the named home"
pass "the process-tree declaration covers a caller that names every home it hands down"

# It must survive the hand-off, or a nested call would lose it and refuse.
# shellcheck disable=SC2016 # $1/$2 are the inner shell's positional args, not ours.
res=$(run_in "$PRIMARY" env FM_HOME="$PRIMARY" FM_HOME_BINDING=test-harness bash -c \
  'FM_HOME="$1" "$2" alpha' _ "$MATE" "$MODE")
expect_code 0 "${res%%|*}" "the process-tree declaration must survive a nested hand-off"
assert_contains "${res#*|}" "local-only" "a nested hand-off must still reach the named home"
pass "the process-tree declaration is not overwritten by a resolved home"

# A misspelling is not the declaration, and must not be read as a path either.
res=$(run_in "$PRIMARY" env FM_HOME="$MATE" FM_HOME_BINDING=test_harness "$MODE" alpha)
expect_code 1 "${res%%|*}" "only the exact process-tree literal may declare a tree"
pass "a near-miss of the process-tree literal declares nothing"

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

# ---------------------------------------------------------------------------
# The consequence the incident actually had: the session lock. Taking the other
# home's lock locks that home out of its own session, so this is the assertion
# that matters most - the refusal must leave no lock behind.
# ---------------------------------------------------------------------------
res=$(run_in "$PRIMARY" env FM_HOME="$MATE" "$LOCK")
expect_code 1 "${res%%|*}" "the session lock must not be taken through an inherited home"
assert_absent "$MATE/state/.lock" "a refused session must not hold the other home's session lock"
pass "an inherited home cannot take another home's session lock"

res=$(run_in "$MATE" env FM_HOME="$MATE" "$LOCK")
expect_code 0 "${res%%|*}" "a mate must still take its own session lock"
assert_present "$MATE/state/.lock" "a mate standing in its own home must hold its own lock"
rm -f "$MATE/state/.lock"
pass "a home standing in itself still takes its own session lock"

# ---------------------------------------------------------------------------
# bin/fm-spawn.sh blanks the layout overrides on every launch line, so a blanked
# override is an empty value, not explicit control. An empty spelling must not
# read as a declaration and wave the inherited home through.
# ---------------------------------------------------------------------------
res=$(run_in "$PRIMARY" env FM_HOME="$MATE" FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= \
  FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_HOME_BINDING= "$MODE" alpha)
expect_code 1 "${res%%|*}" "blanked overrides must not declare an inherited home deliberate"
assert_not_contains "${res#*|}" "local-only" "blanked overrides must not reach the mate's registry"
pass "blanked overrides and a blanked binding are not a deliberate declaration"

# ---------------------------------------------------------------------------
# How far a declaration reaches. Resolving a home must not mint a binding of its
# own, or a process that resolved once would hand that declaration to every
# descendant - including the multiplexer server a spawn starts, whose captured
# environment every later pane inherits - and bless an inherited FM_HOME for a
# session that stands in a different home entirely.
#
# This stand-in is the shape of the ~50 bin/fm-*.sh that source the resolver: it
# resolves a home, carries FM_HOME onward the way a launched session carries it,
# then runs a command from another directory.
# ---------------------------------------------------------------------------
CALLER="$TMP_ROOT/resolve-then-run.sh"
cat > "$CALLER" <<'EOF'
#!/usr/bin/env bash
# usage: resolve-then-run.sh <lib> <default-root> <cd-to> <cmd...>
set -u
lib=$1 default_root=$2 dir=$3
shift 3
# shellcheck source=/dev/null
. "$lib"
fm_home_anchor_resolve "$default_root" || exit 1
export FM_HOME
cd "$dir" || exit 1
exec "$@"
EOF
chmod +x "$CALLER"
LIB="$ROOT/bin/fm-home-anchor-lib.sh"
# shellcheck disable=SC2016 # the binding is read in the launched process, not here.
SHOW_BINDING=('bash' '-c' 'printf %s "${FM_HOME_BINDING-none}"')

res=$(run_in "$MATE" env FM_HOME="$MATE" "$CALLER" "$LIB" "$ROOT" "$PRIMARY" "$MODE" alpha)
expect_code 1 "${res%%|*}" "a resolved home must not bless a descendant standing in another home"
assert_not_contains "${res#*|}" "local-only" "a leaked declaration must not reach the mate's registry"
pass "resolving a home does not bless a later command standing in a different home"

res=$(run_in "$MATE" env FM_HOME="$MATE" "$CALLER" "$LIB" "$ROOT" "$MATE" "${SHOW_BINDING[@]}")
expect_code 0 "${res%%|*}" "the stand-in must resolve its own home"
[ "${res#*|}" = none ] || fail "resolution handed a declaration to the process it launched: ${res#*|}"
pass "resolution hands no declaration to the processes it launches"

# The per-invocation form every cross-home caller in bin/ uses still reaches the
# command tree its caller chose, because that caller passes it explicitly.
res=$(run_in "$PRIMARY" env FM_HOME="$MATE" FM_HOME_BINDING="$MATE" \
  "$CALLER" "$LIB" "$ROOT" "$PRIMARY" "${SHOW_BINDING[@]}")
expect_code 0 "${res%%|*}" "an explicit cross-home binding must still resolve"
[ "${res#*|}" = "$MATE" ] || fail "an explicitly passed binding did not reach the command it was issued for: ${res#*|}"
pass "a binding passed per invocation still reaches the command tree it was issued for"

# The process-tree form belongs to the harness that exported it, so it must keep
# reaching the whole tree and must not be replaced by a resolved home.
res=$(run_in "$PRIMARY" env FM_HOME="$MATE" FM_HOME_BINDING=test-harness \
  "$CALLER" "$LIB" "$ROOT" "$PRIMARY" "${SHOW_BINDING[@]}")
expect_code 0 "${res%%|*}" "the process-tree declaration must still resolve"
[ "${res#*|}" = test-harness ] || fail "the process-tree declaration did not survive resolution: ${res#*|}"
pass "the process-tree declaration keeps reaching the tree its owner drives"

# A same-home hand-off carrying only a partial override set still reaches the
# child, which is the shape firstmate's own nudge and config-reread calls use.
# shellcheck disable=SC2016 # $1/$2 are the inner shell's positional args, not ours.
res=$(run_in "$MATE" env FM_HOME="$MATE" bash -c \
  'FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$2" alpha' _ "$MATE" "$MODE")
expect_code 0 "${res%%|*}" "a same-home hand-off must reach the child"
assert_contains "${res#*|}" "local-only" "a same-home hand-off must keep reading the same home"
pass "a same-home hand-off with a partial override set still reaches the child"

# The same hand-off from a home root OTHER than the one the parent resolved. The
# parent's FM_HOME is the one it assigned itself, so without a binding the child
# would judge it ambient and refuse - which for fm-home-seed.sh's project-mode
# read would empty the captured mode and clone a local-only project anyway.
# shellcheck disable=SC2016 # $1/$2 are the inner shell's positional args, not ours.
res=$(run_in "$PRIMARY" env -u FM_HOME bash -c \
  'FM_HOME="$1" FM_HOME_BINDING="$1" FM_DATA_OVERRIDE="$1/data" "$2" alpha' _ "$MATE" "$MODE")
expect_code 0 "${res%%|*}" "a bound cross-home hand-off must reach the child"
assert_contains "${res#*|}" "local-only" "a bound hand-off must read the home it names"
pass "a hand-off that binds the home it passes reaches the child from any home root"

# ---------------------------------------------------------------------------
# Resolution is idempotent within one process. Rule 1 assigns FM_HOME from the
# code root, and the libraries a script sources resolve again at source time, so
# without a record of this process's own decision the second resolve would judge
# the value the first one assigned as inherited - and a command standing in one
# home root whose code root is a different home root would refuse itself.
# ---------------------------------------------------------------------------
TWICE="$TMP_ROOT/resolve-twice.sh"
cat > "$TWICE" <<'EOF'
#!/usr/bin/env bash
# usage: resolve-twice.sh <lib> <default-root> <switch-to>
# The shape of a bin/fm-*.sh that resolves its home, then sources a library that
# resolves again at source time. <switch-to> is `-` to keep the resolved home, or
# a path to re-point FM_HOME the way a caller that changes home mid-run would.
# Prints the home the second resolve settled on.
set -u
lib=$1 default_root=$2 switch=$3
# shellcheck source=/dev/null
. "$lib"
fm_home_anchor_resolve "$default_root" || exit 1
[ "$switch" = - ] || FM_HOME=$switch
fm_home_anchor_resolve "$default_root" || exit 1
printf '%s\n' "$FM_HOME"
EOF
chmod +x "$TWICE"

res=$(run_in "$MATE" env -u FM_HOME "$TWICE" "$LIB" "$PRIMARY" -)
expect_code 0 "${res%%|*}" "a second resolve must not refuse the home the first one assigned"
[ "${res#*|}" = "$PRIMARY" ] || fail "the second resolve did not settle on the first one's home: ${res#*|}"
pass "a process standing in another home root does not refuse its own resolved home"

# The record covers the one home it was made for, so re-pointing FM_HOME at a
# different home puts the command back under the full rule.
res=$(run_in "$PRIMARY" env -u FM_HOME "$TWICE" "$LIB" "$PRIMARY" "$MATE")
expect_code 1 "${res%%|*}" "a recorded resolution must not bless a later, different FM_HOME"
assert_contains "${res#*|}" "$MATE" "the refusal must name the re-pointed candidate"
pass "a resolved home is a decision about that home, not a blanket blessing"

# The record is a shell variable, so bash presents a same-named environment value
# as an ordinary one. `exec` keeps the PID, so the value below arrives carrying
# the resolving process's OWN PID - the strongest form of the forgery - and must
# still count for nothing.
# shellcheck disable=SC2016 # $$ and the arguments expand in the launched shell.
res=$(run_in "$PRIMARY" env FM_HOME="$MATE" bash -c \
  'export FM_HOME_ANCHOR_RESOLVED_HOME="$1" FM_HOME_ANCHOR_RESOLVED_PID=$$; exec "$2" alpha' \
  _ "$MATE" "$MODE")
expect_code 1 "${res%%|*}" "a resolution record from outside must not bless an inherited home"
assert_not_contains "${res#*|}" "local-only" "an environment-supplied record must not reach the mate"
pass "a resolution record arriving in the environment is not a decision this process made"
