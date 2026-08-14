#!/usr/bin/env bash
# Tests for the secondmate-home pool guard (bin/fm-leased-home-lib.sh,
# bin/fm-leased-home-audit.sh, and the refusals they add to bin/fm-teardown.sh).
#
# A persistent secondmate home and a disposable task worktree are allocated from
# the same treehouse pool, and only the home's durable lease keeps them apart.
# `treehouse return` releases that lease for ANY caller unless it is given a lease
# precondition, so a teardown pointed at a stale worktree= that now names a live
# home releases the lease, kills the secondmate's processes, and drops the home
# into the free pool - where the next ordinary `treehouse get` legitimately hands
# it to an unrelated task. That is the regression these cases lock down.
#
# Matrix:
#   (a) teardown of a task whose worktree= carries a home marker  -> REFUSE, no return
#   (b) same, identified only by data/secondmates.md              -> REFUSE, no return
#   (c) --force does not bypass the home guard                    -> REFUSE, no return
#   (d) teardown of an ordinary task worktree                     -> ALLOW  (no regression)
#   (e) a secondmate retiring its own home                        -> ALLOW  (no regression)
#   (x) a swept child whose worktree= names another's home        -> SKIP, never removed
#   (z) same, registered only in the RETIRING home's own registry -> SKIP, never removed
#
# That refusal has no bypass, so the collided record needs its own way out.
# bin/fm-collided-record-clear.sh is it, and it must stay unable to become a
# general-purpose meta deleter:
#   (A) a record naming another agent's home    -> record cleared, home untouched
#   (B) a record naming an ordinary worktree    -> REFUSE
#   (C) a secondmate's record naming its own home -> REFUSE
#
# Clearing a record is not just unlinking state/<id>.*: two of those records are
# pointers into files that outlive them, and this command is the only remaining
# owner of a collided id, so its cleanup has to match teardown's rather than
# approximate it (bin/fm-task-record-lib.sh owns both):
#   (G) a grok/kimi token record       -> its authorization file goes too
#   (H) an unsafe PR-check artifact    -> REFUSE, whole record preserved
#   (I) quarantined PR-check artifacts -> swept with the record
#
# Spawn guards the same boundary from the other side, in two layers:
#   (t) a pool holding a registered home that lost its lease  -> REFUSE, no window
#   (w) a pool whose registered home is still leased to it    -> ALLOW  (no regression)
#   (u) pool state that cannot be read at all                 -> WARN, spawn proceeds
#   (v) an acquired worktree that carries a home marker       -> REFUSE before launch
#
#   (f) audit: home leased to its own id                          -> OK, exit 0
#   (g) audit: home in the live pool but unleased                 -> LOST_LEASE, exit 1
#   (h) audit: home leased to a different id                      -> HOLDER_MISMATCH, exit 1
#   (i) audit: home in a pool the live listing cannot see         -> OK from pool records
#   (j) audit: pool worktree no pool has a record of              -> UNTRACKED, exit 1
#   (k) audit: a task meta already pointing at another's home     -> COLLISION, exit 1
#   (l) audit: a home seeded as a plain clone                     -> OK, not pooled
#
# The same identifier-reuse shape reaches the endpoint layer: a herdr pane id or
# tmux window index is reissued once its occupant exits, so a task's recorded
# endpoint can come to name another task's live session while still passing an
# existence check. fm-send.sh refuses that ambiguity from firstmate's own
# records, independently of which backend is in play:
#   (m) two live task records naming the same endpoint  -> REFUSE the send
#   (n) an endpoint recorded by one task only           -> ALLOW (no regression)
#   (D) the same collision addressed by the endpoint itself -> REFUSE the send
#
# And it reaches the hook layer: a reused worktree can still hold the PREVIOUS
# occupant's turn-end hook, which fires a wake for a task id that no longer
# exists. fm-spawn.sh clears those actively, because writing its own hook only
# overwrites the one artifact its own harness uses and a secondmate spawn writes
# none at all:
#   (o) a claude Stop hook naming another task    -> removed
#   (p) an opencode plugin naming another task    -> removed
#   (q) a grok/kimi token pointer for another task -> removed
#   (r) this task's own hook                       -> kept
#   (s) a settings.local.json with no firstmate hook -> kept
#   (E) a hook a REAL prior spawn wrote, swept by a REAL later spawn -> removed
#
# And the audit that every one of those refusals names as the diagnostic must not
# answer with a false alarm when it cannot read pool state at all:
#   (F) neither the live listing nor the pool's own records answered -> UNKNOWN
#   (J) a pool state file that errors mid-read rather than not matching -> UNKNOWN
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
AUDIT="$ROOT/bin/fm-leased-home-audit.sh"
TMP_ROOT=$(fm_test_tmproot fm-leased-home-tests)

# --- teardown fixtures ------------------------------------------------------

# Build a case with a project repo, a task worktree, and a treehouse mock that
# logs every invocation so a refusal can be proven to happen BEFORE any return.
# With <home-id>, the secondmate identity marker is committed on main so the task
# worktree checks out CLEAN and already landed: the dirty and landed-work
# refusals then cannot fire, and only the home guard can refuse.
make_teardown_case() {  # <name> [home-id]
  local name=$1 home_id=${2:-} case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin"

  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" tmux gh-axi gh

  git init -q -b main "$case_dir/project"
  git -C "$case_dir/project" commit -q --allow-empty -m baseline
  if [ -n "$home_id" ]; then
    printf '%s\n' "$home_id" > "$case_dir/project/.fm-secondmate-home"
    printf '%s\n' "# home" > "$case_dir/project/AGENTS.md"
    git -C "$case_dir/project" add -A
    git -C "$case_dir/project" commit -q -m "seed home marker"
  fi
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

run_teardown() {  # <case-dir> <task-id> [args...]
  local case_dir=$1 task_id=$2
  shift 2
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" "$task_id" "$@"
}

# Add the operational directories a seeded home carries. Empty directories are
# invisible to git, so this leaves the worktree clean; the identity marker itself
# is committed by make_teardown_case.
mark_secondmate_home() {  # <dir>
  mkdir -p "$1/state" "$1/data" "$1/bin" "$1/projects"
}

register_secondmate() {  # <registry> <id> <home>
  printf -- '- %s - charter (home: %s; scope: test scope; projects: alpha; added 2026-08-14)\n' \
    "$2" "$3" >> "$1"
}

assert_no_return_ran() {  # <case-dir> <label>
  local log="$1/treehouse.log"
  [ -f "$log" ] || return 0
  ! grep -q "return" "$log" \
    || fail "$2: treehouse return ran despite the refusal"$'\n'"--- treehouse.log ---"$'\n'"$(cat "$log")"
}

# (a) A task worktree that is really a marked secondmate home is refused.
case_dir=$(make_teardown_case marker-home dictate)
mark_secondmate_home "$case_dir/wt"
fm_write_meta "$case_dir/state/task-x1.meta" \
  "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
  "worktree=$case_dir/wt" "project=$case_dir/project" \
  "harness=echo" "kind=ship" "yolo=off"
out=$(run_teardown "$case_dir" task-x1 2>&1); rc=$?
expect_code 1 "$rc" "marker-home teardown"
assert_contains "$out" "REFUSED" "marker-home teardown refuses"
assert_contains "$out" "dictate" "marker-home refusal names the secondmate"
assert_no_return_ran "$case_dir" "marker-home"
assert_present "$case_dir/wt/.fm-secondmate-home" "marker-home: the home marker survived"
pass "fm-teardown.sh: refuses a task worktree that is a marked secondmate home"

# (b) Identified only by the registry, with no marker in the directory.
case_dir=$(make_teardown_case registry-home)
register_secondmate "$case_dir/data/secondmates.md" explore "$case_dir/wt"
fm_write_meta "$case_dir/state/task-x1.meta" \
  "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
  "worktree=$case_dir/wt" "project=$case_dir/project" \
  "harness=echo" "kind=ship" "yolo=off"
out=$(run_teardown "$case_dir" task-x1 2>&1); rc=$?
expect_code 1 "$rc" "registry-home teardown"
assert_contains "$out" "REFUSED" "registry-home teardown refuses"
assert_contains "$out" "explore" "registry-home refusal names the secondmate"
assert_no_return_ran "$case_dir" "registry-home"
pass "fm-teardown.sh: refuses a task worktree registered as a secondmate home"

# (c) --force skips the dirty and landed-work checks but must not skip this one:
# the home belongs to another agent, so there is no work here to discard.
# --force is also the path that reaches the branch deletion and the turn-end hook
# removal, both of which run ahead of the treehouse return: a guard that refused
# only at the return would still have silenced this secondmate's turn-end wakes
# and dropped its branch first, so the refusal has to leave all of that intact.
case_dir=$(make_teardown_case forced-home dictate)
mark_secondmate_home "$case_dir/wt"
mkdir -p "$case_dir/wt/.claude" "$case_dir/wt/.opencode/plugins"
printf '{"hooks":{"Stop":[]}}\n' > "$case_dir/wt/.claude/settings.local.json"
printf 'export const FmTurnEnd = {}\n' > "$case_dir/wt/.opencode/plugins/fm-turn-end.js"
printf 'token=dictate.grok-turnend-token\n' > "$case_dir/wt/.fm-grok-turnend"
fm_write_meta "$case_dir/state/task-x1.meta" \
  "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
  "worktree=$case_dir/wt" "project=$case_dir/project" \
  "harness=echo" "kind=ship" "yolo=off"
out=$(run_teardown "$case_dir" task-x1 --force 2>&1); rc=$?
expect_code 1 "$rc" "forced-home teardown"
assert_contains "$out" "REFUSED" "--force still refuses a secondmate home"
assert_no_return_ran "$case_dir" "forced-home"
assert_present "$case_dir/wt/.fm-secondmate-home" "forced-home: the home marker survived"
for f in .claude/settings.local.json .opencode/plugins/fm-turn-end.js .fm-grok-turnend; do
  assert_present "$case_dir/wt/$f" \
    "forced-home: the home's $f was removed before the refusal printed"
done
[ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" = fm/task-x1 ] \
  || fail "forced-home: the home's branch was detached or deleted before the refusal printed"
pass "fm-teardown.sh: --force does not bypass the secondmate-home guard"

# (d) An ordinary task worktree is untouched by the guard.
case_dir=$(make_teardown_case ordinary-worktree)
fm_write_meta "$case_dir/state/task-x1.meta" \
  "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
  "worktree=$case_dir/wt" "project=$case_dir/project" \
  "harness=echo" "kind=ship" "yolo=off"
out=$(run_teardown "$case_dir" task-x1 --force 2>&1); rc=$?
expect_code 0 "$rc" "ordinary teardown"
assert_not_contains "$out" "REFUSED" "ordinary worktree is not refused"
assert_grep "return --force $case_dir/wt" "$case_dir/treehouse.log" \
  "ordinary worktree: teardown still returned it to the pool"
pass "fm-teardown.sh: an ordinary task worktree still returns to the pool"

# (e) A secondmate retiring its OWN home is the one caller allowed through.
case_dir=$(make_teardown_case self-retire dictate)
mark_secondmate_home "$case_dir/wt"
register_secondmate "$case_dir/data/secondmates.md" dictate "$case_dir/wt"
fm_write_secondmate_meta "$case_dir/state/dictate.meta" "$case_dir/wt" \
  "firstmate:fm-dictate" alpha echo
out=$(run_teardown "$case_dir" dictate --force 2>&1); rc=$?
expect_code 0 "$rc" "self-retire teardown"$'\n'"--- output ---"$'\n'"$out"
assert_not_contains "$out" "REFUSED" "a secondmate retiring its own home is not refused"
pass "fm-teardown.sh: a secondmate can still retire its own home"

# (x) A forced secondmate teardown sweeps its home's own children, and a child
# whose recorded worktree= names ANOTHER secondmate's home has to be skipped
# outright: that sweep answers a failed return with `rm -rf`, so an ownership
# refusal it cannot tell apart from a failure would delete the very home the
# guard exists to protect - and the hook removal it runs first would silence that
# home's turn-end wakes on the way there.
case_dir=$(make_teardown_case child-foreign-home dictate)
mark_secondmate_home "$case_dir/wt"
register_secondmate "$case_dir/data/secondmates.md" dictate "$case_dir/wt"
git -C "$case_dir/project" worktree add -q --detach "$case_dir/foreign-home"
printf '%s\n' explore > "$case_dir/foreign-home/.fm-secondmate-home"
mkdir -p "$case_dir/foreign-home/.claude" "$case_dir/foreign-home/.opencode/plugins"
printf '{"hooks":{"Stop":[]}}\n' > "$case_dir/foreign-home/.claude/settings.local.json"
printf 'export const FmTurnEnd = {}\n' > "$case_dir/foreign-home/.opencode/plugins/fm-turn-end.js"
printf 'token=explore.grok-turnend-token\n' > "$case_dir/foreign-home/.fm-grok-turnend"
fm_write_meta "$case_dir/wt/state/child-a.meta" \
  "window=firstmate:fm-child-a" "endpoint_task_id=child-a" \
  "worktree=$case_dir/foreign-home" "project=$case_dir/project" \
  "harness=echo" "kind=ship" "yolo=off"
fm_write_secondmate_meta "$case_dir/state/dictate.meta" "$case_dir/wt" \
  "firstmate:fm-dictate" alpha echo
: > "$case_dir/treehouse.log"
out=$(run_teardown "$case_dir" dictate --force 2>&1); rc=$?
expect_code 1 "$rc" "child-foreign-home teardown reports declined work"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "REFUSED" "the child sweep refuses a child recorded inside a foreign home"
assert_contains "$out" "explore" "the refusal names the secondmate whose home the child recorded"
assert_present "$case_dir/foreign-home/.fm-secondmate-home" \
  "child-foreign-home: the foreign home was removed by the child sweep"
for f in .claude/settings.local.json .opencode/plugins/fm-turn-end.js .fm-grok-turnend; do
  assert_present "$case_dir/foreign-home/$f" \
    "child-foreign-home: the foreign home's $f was removed by the child sweep"
done
assert_no_grep "return --force $case_dir/foreign-home" "$case_dir/treehouse.log" \
  "child-foreign-home: the foreign home was returned to the pool"
# The skip message promises the child record survives, so the retirement of the
# home holding it has to stop too: returning that home resets the slot and takes
# the very record the operator was told to reconcile with it.
assert_present "$case_dir/wt/state/child-a.meta" \
  "child-foreign-home: the skipped child's record was deleted anyway"
assert_no_grep "return --force $case_dir/wt" "$case_dir/treehouse.log" \
  "child-foreign-home: the parent home was returned to the pool despite declined work"
pass "fm-teardown.sh: a child recorded inside a foreign home is skipped, never removed"

# (z) The same skip has to fire for a home registered ONLY in the retiring home's
# own registry: a home can register grandchildren the primary has never seen, and
# the registry is the independent second source for a home whose marker is gone.
case_dir=$(make_teardown_case child-foreign-home-subregistry dictate)
mark_secondmate_home "$case_dir/wt"
register_secondmate "$case_dir/data/secondmates.md" dictate "$case_dir/wt"
git -C "$case_dir/project" worktree add -q --detach "$case_dir/grandchild-home"
# No marker of its own: the registry is the only thing that can identify it, and
# the ONLY registry naming it is the retiring home's, not the primary's.
rm -f "$case_dir/grandchild-home/.fm-secondmate-home"
register_secondmate "$case_dir/wt/data/secondmates.md" wander "$case_dir/grandchild-home"
fm_write_meta "$case_dir/wt/state/child-a.meta" \
  "window=firstmate:fm-child-a" "endpoint_task_id=child-a" \
  "worktree=$case_dir/grandchild-home" "project=$case_dir/project" \
  "harness=echo" "kind=ship" "yolo=off"
fm_write_secondmate_meta "$case_dir/state/dictate.meta" "$case_dir/wt" \
  "firstmate:fm-dictate" alpha echo
: > "$case_dir/treehouse.log"
out=$(run_teardown "$case_dir" dictate --force 2>&1); rc=$?
expect_code 1 "$rc" "child-foreign-home-subregistry teardown"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "wander" "the refusal names the grandchild home's secondmate"
assert_present "$case_dir/grandchild-home" \
  "child-foreign-home-subregistry: the grandchild home was removed"
assert_no_grep "return --force $case_dir/grandchild-home" "$case_dir/treehouse.log" \
  "child-foreign-home-subregistry: the grandchild home was returned to the pool"
pass "fm-teardown.sh: the child sweep consults the retiring home's own registry"

# --- collided-record clearing -----------------------------------------------

CLEAR="$ROOT/bin/fm-collided-record-clear.sh"

run_clear() {  # <case-dir> <task-id>
  local case_dir=$1 task_id=$2
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$CLEAR" "$task_id"
}

# (A) The way out of the teardown refusal: the record goes, the home stays. Every
# file, the lease, and the turn-end hooks of the home it named are untouched,
# which is the whole reason this is a separate command rather than a --force.
case_dir=$(make_teardown_case clear-collided dictate)
mark_secondmate_home "$case_dir/wt"
mkdir -p "$case_dir/wt/.claude"
printf '{"hooks":{"Stop":[]}}\n' > "$case_dir/wt/.claude/settings.local.json"
printf 'token=dictate.grok-turnend-token\n' > "$case_dir/wt/.fm-grok-turnend"
fm_write_meta "$case_dir/state/task-x1.meta" \
  "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
  "worktree=$case_dir/wt" "project=$case_dir/project" \
  "harness=echo" "kind=ship" "yolo=off"
: > "$case_dir/state/task-x1.status"
: > "$case_dir/state/task-x1.turn-ended"
: > "$case_dir/treehouse.log"
# Teardown is the command an operator reaches for first, and it must keep saying
# no - including under --force - and name this one instead.
out=$(run_teardown "$case_dir" task-x1 --force 2>&1); rc=$?
expect_code 1 "$rc" "clear-collided: teardown of a collided record"
assert_contains "$out" "fm-collided-record-clear.sh task-x1" \
  "the teardown refusal names the supported way out"
out=$(run_clear "$case_dir" task-x1 2>&1); rc=$?
expect_code 0 "$rc" "clear-collided run"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "firstmate:fm-task-x1" "the cleared record's endpoint is reported"
for suffix in meta status turn-ended; do
  assert_absent "$case_dir/state/task-x1.$suffix" \
    "clear-collided: the stale $suffix record survived"
done
assert_present "$case_dir/wt/.fm-secondmate-home" "clear-collided: the home marker was removed"
assert_present "$case_dir/wt/.claude/settings.local.json" \
  "clear-collided: the home's turn-end hook was removed"
assert_present "$case_dir/wt/.fm-grok-turnend" "clear-collided: the home's hook pointer was removed"
assert_no_return_ran "$case_dir" "clear-collided"
[ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" = fm/task-x1 ] \
  || fail "clear-collided: the home's branch was touched"
pass "fm-collided-record-clear.sh: clears the stale record and leaves the home alone"

# (B) An ordinary task worktree is not a collision, so this must refuse: teardown
# owns that record, and a command that cleared it would be a meta deleter.
case_dir=$(make_teardown_case clear-ordinary)
fm_write_meta "$case_dir/state/task-x1.meta" \
  "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
  "worktree=$case_dir/wt" "project=$case_dir/project" \
  "harness=echo" "kind=ship" "yolo=off"
out=$(run_clear "$case_dir" task-x1 2>&1); rc=$?
expect_code 1 "$rc" "clear-ordinary run"
assert_contains "$out" "REFUSED" "an ordinary worktree record is refused"
assert_contains "$out" "fm-teardown.sh" "the refusal names the command that owns that record"
assert_present "$case_dir/state/task-x1.meta" "clear-ordinary: an ordinary record was deleted"
pass "fm-collided-record-clear.sh: refuses a record that names an ordinary worktree"

# (C) A secondmate's own home is not a collision either; retiring it has to go
# through teardown, which returns its lease.
case_dir=$(make_teardown_case clear-own-home dictate)
mark_secondmate_home "$case_dir/wt"
register_secondmate "$case_dir/data/secondmates.md" dictate "$case_dir/wt"
fm_write_secondmate_meta "$case_dir/state/dictate.meta" "$case_dir/wt" \
  "firstmate:fm-dictate" alpha echo
out=$(run_clear "$case_dir" dictate 2>&1); rc=$?
expect_code 1 "$rc" "clear-own-home run"
assert_contains "$out" "REFUSED" "a secondmate's own home record is refused"
assert_present "$case_dir/state/dictate.meta" "clear-own-home: a live home record was deleted"
pass "fm-collided-record-clear.sh: refuses a secondmate's record for its own home"

# (G) The grok and kimi turn-end tokens are pointers into an authorization file
# under the harness's global hooks dir, and the token string exists ONLY in the
# record. Unlinking the record without the file it names would strand an
# authorization that still permits a turn-end touch for a dead task id, with
# nothing left anywhere able to find that file again. The pointer inside the
# foreign home is deliberately left alone - that home is off limits - which is
# precisely why the authorization has to go.
case_dir=$(make_teardown_case clear-turnend-auth dictate)
mark_secondmate_home "$case_dir/wt"
fake_home="$case_dir/fakehome"
grok_auth="$fake_home/.grok/hooks/fm-turn-end.d"
kimi_auth="$fake_home/.kimi-code/fm-turn-end.d"
mkdir -p "$grok_auth" "$kimi_auth"
printf '%s\n' "$case_dir/state/task-x1.turn-ended" > "$grok_auth/fm.aaaabbbbcccc"
printf '%s\n' "$case_dir/state/task-x1.turn-ended" > "$kimi_auth/fm.ddddeeeeffff"
printf 'fm.aaaabbbbcccc\n' > "$case_dir/state/task-x1.grok-turnend-token"
printf 'fm.ddddeeeeffff\n' > "$case_dir/state/task-x1.kimi-turnend-token"
printf 'token=fm.aaaabbbbcccc\n' > "$case_dir/wt/.fm-grok-turnend"
fm_write_meta "$case_dir/state/task-x1.meta" \
  "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
  "worktree=$case_dir/wt" "project=$case_dir/project" \
  "harness=grok" "kind=ship" "yolo=off"
out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
  HOME="$fake_home" GROK_HOME="$fake_home/.grok" \
  PATH="$case_dir/fakebin:$PATH" "$CLEAR" task-x1 2>&1); rc=$?
expect_code 0 "$rc" "clear-turnend-auth run"$'\n'"--- output ---"$'\n'"$out"
assert_absent "$grok_auth/fm.aaaabbbbcccc" \
  "clear-turnend-auth: the grok turn-end authorization outlived the token record"
assert_absent "$kimi_auth/fm.ddddeeeeffff" \
  "clear-turnend-auth: the kimi turn-end authorization outlived the token record"
assert_absent "$case_dir/state/task-x1.grok-turnend-token" \
  "clear-turnend-auth: the grok token record survived"
assert_present "$case_dir/wt/.fm-grok-turnend" \
  "clear-turnend-auth: the foreign home's hook pointer was touched"
pass "fm-collided-record-clear.sh: removes the turn-end authorization its token record named"

# (H) The PR-check artifacts have one hardened removal protocol in this repo, and
# an artifact that is a symlink is refused rather than force-removed. Because the
# refusal preserves task state, it has to be raised before anything at all is
# unlinked - a partial clear would leave a record nothing can finish retiring.
case_dir=$(make_teardown_case clear-unsafe-pr-artifact dictate)
mark_secondmate_home "$case_dir/wt"
fm_write_meta "$case_dir/state/task-x1.meta" \
  "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
  "worktree=$case_dir/wt" "project=$case_dir/project" \
  "harness=echo" "kind=ship" "yolo=off"
: > "$case_dir/state/task-x1.status"
: > "$case_dir/elsewhere-pr-poll"
ln -s "$case_dir/elsewhere-pr-poll" "$case_dir/state/task-x1.pr-poll"
out=$(run_clear "$case_dir" task-x1 2>&1); rc=$?
expect_code 1 "$rc" "clear-unsafe-pr-artifact run"
assert_contains "$out" "REFUSED" "an unsafe PR-check artifact is refused"
assert_contains "$out" "preserving task state" "the refusal says the record is preserved"
for suffix in meta status pr-poll; do
  assert_present "$case_dir/state/task-x1.$suffix" \
    "clear-unsafe-pr-artifact: $suffix was removed despite the refusal"
done
assert_present "$case_dir/elsewhere-pr-poll" \
  "clear-unsafe-pr-artifact: the symlink target outside state/ was followed and removed"
pass "fm-collided-record-clear.sh: refuses an unsafe PR-check artifact and preserves the record"

# (I) A clean PR-check artifact set goes through the same protocol, quarantine
# included: teardown now refuses a collided record outright, so anything this
# command leaves behind has no other owner left to remove it.
case_dir=$(make_teardown_case clear-pr-artifacts dictate)
mark_secondmate_home "$case_dir/wt"
fm_write_meta "$case_dir/state/task-x1.meta" \
  "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
  "worktree=$case_dir/wt" "project=$case_dir/project" \
  "harness=echo" "kind=ship" "yolo=off"
printf 'check\n' > "$case_dir/state/task-x1.check.sh"
printf 'poll\n' > "$case_dir/state/task-x1.pr-poll"
quarantine="$case_dir/state/.pr-check-quarantine"
mkdir -p "$quarantine"
chmod 700 "$quarantine"
printf 'quarantined\n' > "$quarantine/task-x1.diagnostic"
chmod 600 "$quarantine/task-x1.diagnostic"
out=$(run_clear "$case_dir" task-x1 2>&1); rc=$?
expect_code 0 "$rc" "clear-pr-artifacts run"$'\n'"--- output ---"$'\n'"$out"
for suffix in meta check.sh pr-poll; do
  assert_absent "$case_dir/state/task-x1.$suffix" \
    "clear-pr-artifacts: $suffix survived the clear"
done
assert_absent "$quarantine/task-x1.diagnostic" \
  "clear-pr-artifacts: a quarantined artifact was orphaned with no owner left to remove it"
pass "fm-collided-record-clear.sh: sweeps the PR-check artifacts and quarantine with the record"

# --- spawn refusal cases ----------------------------------------------------

SPAWN="$ROOT/bin/fm-spawn.sh"

# A home, a project, and one pool-shaped worktree cut from it, plus a tmux stub
# that LOGS every call. The log is what separates the two spawn layers: the
# pre-allocation gate must refuse with no `new-window` in it at all, while the
# post-allocation refusal happens after the window exists.
make_spawn_case() {  # <name> <task-id>
  local name=$1 id=$2 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/home/data/$id" "$case_dir/home/projects" "$case_dir/home/state" \
    "$case_dir/home/config" "$fakebin" "$case_dir/.treehouse/pool-a/1"
  printf 'codex\n' > "$case_dir/home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$case_dir/home/data/$id/brief.md"
  touch "$case_dir/home/state/.last-watcher-beat"
  fm_git_init_commit "$case_dir/project"
  git -C "$case_dir/project" worktree add -q --detach "$case_dir/.treehouse/pool-a/1/project"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TMUX_LOG:-/dev/null}"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" sleep gh-axi gh
  : > "$case_dir/tmux.log"
  printf '%s\n' "$case_dir"
}

# Stand in for `treehouse status --json`. With no entries the pool reads clean;
# with `fail` the command errors, which is the "pool state cannot be read" case.
fake_spawn_treehouse() {  # <case-dir> <fail|entry-json>
  local case_dir=$1 body=$2
  if [ "$body" = fail ]; then
    cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = status ] && exit 1
exit 0
SH
  else
    cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = status ]; then
  printf '%s\n' '[$body]'
  exit 0
fi
exit 0
SH
  fi
  chmod +x "$case_dir/fakebin/treehouse"
}

run_spawn() {  # <case-dir> <task-id> <settled-pane-path> [project-arg] [extra-arg...]
  local case_dir=$1 id=$2 pane=$3 project_arg=${4:-$1/project}
  shift $(( $# > 4 ? 4 : $# ))
  FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/home/state" FM_DATA_OVERRIDE="$case_dir/home/data" \
  FM_PROJECTS_OVERRIDE="$case_dir/home/projects" FM_CONFIG_OVERRIDE="$case_dir/home/config" \
  FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
  FM_FAKE_PANE_PATH="$pane" FM_TMUX_LOG="$case_dir/tmux.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$id" "$project_arg" "$@" 2>&1
}

# (t) A pool that currently holds an unleased registered home can hand that home
# to the next ordinary acquisition, so the whole spawn is refused - and refused
# before any endpoint exists, since nothing here would close an orphan window.
if command -v jq >/dev/null 2>&1; then
  case_dir=$(make_spawn_case spawn-pool-unleased pool-gate-task)
  home="$case_dir/.treehouse/pool-a/1/project"
  fake_spawn_treehouse "$case_dir" \
    "{\"name\":\"1\",\"path\":\"$home\",\"status\":\"in-use\",\"lease_holder\":\"\"}"
  register_secondmate "$case_dir/home/data/secondmates.md" dictate "$home"
  out=$(run_spawn "$case_dir" pool-gate-task "$home"); rc=$?
  expect_code 1 "$rc" "spawn into a pool holding an unleased home"
  assert_contains "$out" "REFUSED" "the pool gate refuses the spawn"
  assert_contains "$out" "dictate" "the refusal names the secondmate whose home is exposed"
  assert_no_grep "new-window" "$case_dir/tmux.log" \
    "spawn-pool-unleased: a window was created before the refusal"
  assert_absent "$case_dir/home/state/pool-gate-task.meta" \
    "spawn-pool-unleased: a task record survived the refusal"
  pass "fm-spawn.sh: refuses to allocate from a pool holding an unleased secondmate home"

  # (w) The other side of that comparison: a home still leased to its own id is
  # protected, so the pool is safe to allocate from. treehouse reports a leased
  # slot as status "leased" even while its processes run, and if that comparison
  # ever drifted this gate would hard-fail every spawn into any pool that holds a
  # secondmate home at all.
  case_dir=$(make_spawn_case spawn-pool-leased leased-pool-task)
  home="$case_dir/.treehouse/pool-a/1/project"
  wt="$case_dir/.treehouse/pool-a/2/project"
  git -C "$case_dir/project" worktree add -q --detach "$wt"
  fake_spawn_treehouse "$case_dir" \
    "{\"name\":\"1\",\"path\":\"$home\",\"status\":\"leased\",\"lease_holder\":\"dictate\"},{\"name\":\"2\",\"path\":\"$wt\",\"status\":\"in-use\",\"lease_holder\":\"\"}"
  register_secondmate "$case_dir/home/data/secondmates.md" dictate "$home"
  out=$(run_spawn "$case_dir" leased-pool-task "$wt"); rc=$?
  expect_code 0 "$rc" "spawn into a pool whose home is properly leased"$'\n'"--- output ---"$'\n'"$out"
  assert_not_contains "$out" "REFUSED" "a home leased to its own id must not refuse the spawn"
  assert_present "$case_dir/home/state/leased-pool-task.meta" \
    "spawn-pool-leased: the spawn did not complete"
  pass "fm-spawn.sh: a pool whose secondmate home is still leased allocates normally"

  # (y) The documented spawn form names a project as `projects/<name>`, which is
  # only a directory after it is resolved against the home's projects dir. The
  # gate has to read the pool of the project actually being spawned into, not of
  # a path that happens to resolve relative to the caller's cwd - otherwise it
  # warns that pool state is unreadable on every such spawn and protects nothing.
  case_dir=$(make_spawn_case spawn-relative-project rel-proj-task)
  home="$case_dir/.treehouse/pool-a/1/project"
  ln -s "$case_dir/project" "$case_dir/home/projects/proj"
  fake_spawn_treehouse "$case_dir" \
    "{\"name\":\"1\",\"path\":\"$home\",\"status\":\"in-use\",\"lease_holder\":\"\"}"
  register_secondmate "$case_dir/home/data/secondmates.md" dictate "$home"
  out=$(run_spawn "$case_dir" rel-proj-task "$home" "projects/proj"); rc=$?
  expect_code 1 "$rc" "spawn named by projects/<name> into a pool holding an unleased home"
  assert_contains "$out" "REFUSED" "the gate refuses a spawn named by its projects/<name> form"
  assert_not_contains "$out" "could not read the treehouse pool" \
    "the gate read the resolved project dir, not the raw argument"
  pass "fm-spawn.sh: the pool gate resolves the projects/<name> spawn form"
else
  pass "fm-spawn.sh: pool-lease gate cases skipped (jq not installed)"
fi

# (u) Pool state that cannot be read is unknown, not safe - but it must not be
# fatal either: the unconditional guarantees are the teardown guard and the
# post-allocation assertion, so a missing or broken optional tool only warns.
case_dir=$(make_spawn_case spawn-pool-unreadable warn-task)
fake_spawn_treehouse "$case_dir" fail
# A registered home elsewhere in the same pool: whether it still holds its lease
# is exactly what the unreadable pool state hides.
register_secondmate "$case_dir/home/data/secondmates.md" dictate \
  "$case_dir/.treehouse/pool-a/2/project"
out=$(run_spawn "$case_dir" warn-task "$case_dir/.treehouse/pool-a/1/project"); rc=$?
expect_code 0 "$rc" "spawn with unreadable pool state"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "warning" "unreadable pool state is reported"
assert_contains "$out" "skipping the secondmate-home lease check" \
  "the warning says which check was skipped"
assert_not_contains "$out" "REFUSED" "unreadable pool state must not block the spawn"
assert_present "$case_dir/home/state/warn-task.meta" \
  "spawn-pool-unreadable: the spawn did not complete"
pass "fm-spawn.sh: unreadable pool state warns and does not block a spawn"

# (v) The post-allocation half: whatever the pool reported, a worktree that turns
# out to be a marked home is refused before the agent launches into it and takes
# that home's session lock.
case_dir=$(make_spawn_case spawn-acquired-home marker-task)
home="$case_dir/.treehouse/pool-a/1/project"
printf '%s\n' dictate > "$home/.fm-secondmate-home"
fake_spawn_treehouse "$case_dir" ""
out=$(run_spawn "$case_dir" marker-task "$home"); rc=$?
expect_code 1 "$rc" "spawn handed a marked secondmate home"
assert_contains "$out" "REFUSED" "the acquired home is refused"
assert_contains "$out" "dictate" "the refusal names the secondmate whose home was acquired"
assert_absent "$case_dir/home/state/marker-task.meta" \
  "spawn-acquired-home: a task record survived the refusal"
assert_grep "new-window" "$case_dir/tmux.log" \
  "spawn-acquired-home: expected this layer to refuse AFTER the window exists, unlike the pool gate"
assert_present "$home/.fm-secondmate-home" "spawn-acquired-home: the home marker survived"
pass "fm-spawn.sh: refuses a worktree that is a secondmate home before launching into it"

# --- endpoint-collision cases -----------------------------------------------

SEND="$ROOT/bin/fm-send.sh"

# A tmux stub is enough here: the refusal is decided from firstmate's own
# records, before any backend is asked anything, so it holds for every backend.
make_send_case() {  # <name>
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s arg=%s\n' "$target" "${1:-}" >> "$FM_TMUX_LOG"
    exit 0 ;;
  display-message)
    cursor=0
    while [ $# -gt 0 ]; do
      case "$1" in
        *cursor_y*) cursor=1; shift ;;
        *) shift ;;
      esac
    done
    [ "$cursor" = 1 ] && { printf '1\n'; exit 0; }
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/sleep"
  printf '%s\n' "$case_dir"
}

run_send() {  # <case-dir> <target> <message>
  local case_dir=$1
  shift
  PATH="$case_dir/fakebin:$PATH" FM_HOME="$case_dir" FM_ROOT_OVERRIDE="$case_dir" \
  FM_TMUX_LOG="$case_dir/tmux.log" FM_SEND_SETTLE=0 \
    "$SEND" "$@"
}

# (m) Two live records naming one endpoint: the send must not guess.
case_dir=$(make_send_case endpoint-collision)
: > "$case_dir/tmux.log"
fm_write_meta "$case_dir/state/scraper.meta" "window=sess:fm-shared" "kind=secondmate"
fm_write_meta "$case_dir/state/vectordb.meta" "window=sess:fm-shared" "kind=secondmate"
out=$(run_send "$case_dir" scraper "steer" 2>&1); rc=$?
expect_code 1 "$rc" "endpoint-collision send"
assert_contains "$out" "recorded by both" "the send refuses an ambiguous endpoint"
assert_contains "$out" "vectordb" "the refusal names the other task holding the endpoint"
[ ! -s "$case_dir/tmux.log" ] \
  || fail "endpoint-collision: text was typed despite the refusal"$'\n'"$(cat "$case_dir/tmux.log")"
pass "fm-send.sh: refuses to steer an endpoint two task records both claim"

# (n) One record, one endpoint: unchanged.
case_dir=$(make_send_case endpoint-unique)
: > "$case_dir/tmux.log"
fm_write_meta "$case_dir/state/scraper.meta" "window=sess:fm-scraper" "kind=secondmate"
fm_write_meta "$case_dir/state/vectordb.meta" "window=sess:fm-vectordb" "kind=secondmate"
out=$(run_send "$case_dir" scraper "steer" 2>&1); rc=$?
expect_code 0 "$rc" "endpoint-unique send"$'\n'"--- output ---"$'\n'"$out"
assert_grep "sess:fm-scraper" "$case_dir/tmux.log" "endpoint-unique: the message reached its own endpoint"
pass "fm-send.sh: an unambiguous endpoint still receives its message"

# (D) Addressing the pane you can see instead of the task takes the other
# resolution branch, which answers with the FIRST record that matches in glob
# order. That is the same silent guess, so it has to refuse the same way.
case_dir=$(make_send_case endpoint-collision-explicit)
: > "$case_dir/tmux.log"
fm_write_meta "$case_dir/state/scraper.meta" "window=sess:fm-shared" "kind=secondmate"
fm_write_meta "$case_dir/state/vectordb.meta" "window=sess:fm-shared" "kind=secondmate"
out=$(run_send "$case_dir" sess:fm-shared "steer" 2>&1); rc=$?
expect_code 1 "$rc" "endpoint-collision-explicit send"
assert_contains "$out" "recorded by both" "the explicit-endpoint branch refuses an ambiguous endpoint"
[ ! -s "$case_dir/tmux.log" ] \
  || fail "endpoint-collision-explicit: text was typed despite the refusal"$'\n'"$(cat "$case_dir/tmux.log")"
pass "fm-send.sh: refuses an ambiguous endpoint addressed by the endpoint itself"

# --- stale turn-end hook cases ----------------------------------------------

# shellcheck source=/dev/null
. "$ROOT/bin/fm-turnend-artifact-lib.sh"

# Build a worktree holding the exact artifacts bin/fm-spawn.sh writes, for the
# task id given. The literal shapes are copied from that script's hook block.
make_hook_worktree() {  # <name> <owning-task-id> <state-dir>
  local name=$1 owner=$2 state=$3 wt
  wt="$TMP_ROOT/$name"
  mkdir -p "$wt/.claude" "$wt/.opencode/plugins"
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch %s"}]}]}}\n' \
    "'$state/$owner.turn-ended'" > "$wt/.claude/settings.local.json"
  cat > "$wt/.opencode/plugins/fm-turn-end.js" <<JS
export const FmTurnEnd = async ({ \$ }) => ({
  event: async ({ event }) => {
    if (event.type === "session.idle") await \$\`touch $state/$owner.turn-ended\`
  },
})
JS
  printf 'token=%s\n' "$owner.grok-turnend-token" > "$wt/.fm-grok-turnend"
  printf 'token=%s\n' "$owner.kimi-turnend-token" > "$wt/.fm-kimi-turnend"
  printf '%s\n' "$wt"
}

# (o,p,q) Every artifact left by a previous occupant is identified and removed.
wt=$(make_hook_worktree stale-hooks vector-fingerprint-instruction-design /home/x/state)
for f in .claude/settings.local.json .opencode/plugins/fm-turn-end.js .fm-grok-turnend .fm-kimi-turnend; do
  got=$(fm_turnend_artifact_task_id "$wt/$f")
  [ "$got" = vector-fingerprint-instruction-design ] \
    || fail "stale-hooks: $f resolved owner '$got', expected the previous occupant's task id"
done
out=$(fm_turnend_clear_foreign "$wt" dictate 2>&1)
assert_contains "$out" "previous occupant" "the sweep reports what it removed"
for f in .claude/settings.local.json .opencode/plugins/fm-turn-end.js .fm-grok-turnend .fm-kimi-turnend; do
  assert_absent "$wt/$f" "stale-hooks: $f survived the sweep"
done
pass "fm-turnend-artifact-lib.sh: clears every turn-end hook a prior occupant left behind"

# (r) This task's own hooks are never swept.
wt=$(make_hook_worktree own-hooks dictate /home/x/state)
fm_turnend_clear_foreign "$wt" dictate 2>/dev/null
for f in .claude/settings.local.json .opencode/plugins/fm-turn-end.js .fm-grok-turnend .fm-kimi-turnend; do
  assert_present "$wt/$f" "own-hooks: the sweep removed this task's own $f"
done
pass "fm-turnend-artifact-lib.sh: leaves this task's own turn-end hooks in place"

# (s) A settings file with no firstmate turn-end signature is not firstmate's to
# delete - the captain may have written it.
wt="$TMP_ROOT/foreign-settings"
mkdir -p "$wt/.claude"
printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' > "$wt/.claude/settings.local.json"
[ -z "$(fm_turnend_artifact_task_id "$wt/.claude/settings.local.json")" ] \
  || fail "foreign-settings: a non-hook settings file was claimed as a turn-end artifact"
fm_turnend_clear_foreign "$wt" dictate 2>/dev/null
assert_present "$wt/.claude/settings.local.json" "foreign-settings: a non-hook settings file was deleted"
pass "fm-turnend-artifact-lib.sh: leaves a settings file carrying no turn-end hook alone"

# (E) The cases above build their artifacts by hand, so nothing there ties the
# reader to the writer: if bin/fm-spawn.sh ever changed the shape of the hook it
# writes, the parser would stop matching, the sweep would silently clear nothing,
# and those cases would still pass against the stale copy. This one drives the
# real script on both ends - one spawn WRITES the hook, a later spawn into the
# same reused slot has to sweep it - and it uses a different harness for the
# second spawn on purpose, because writing your own hook only ever overwrites the
# one artifact your own harness uses.
case_dir=$(make_spawn_case spawn-hook-handover first-occupant)
slot="$case_dir/.treehouse/pool-a/1/project"
mkdir -p "$case_dir/home/data/second-occupant"
printf 'brief for second-occupant\n' > "$case_dir/home/data/second-occupant/brief.md"
fake_spawn_treehouse "$case_dir" ""
out=$(run_spawn "$case_dir" first-occupant "$slot" "$case_dir/project" --harness claude); rc=$?
expect_code 0 "$rc" "spawn-hook-handover first spawn"$'\n'"--- output ---"$'\n'"$out"
assert_present "$slot/.claude/settings.local.json" \
  "spawn-hook-handover: the first spawn wrote no claude turn-end hook to sweep"
got=$(fm_turnend_artifact_task_id "$slot/.claude/settings.local.json")
[ "$got" = first-occupant ] \
  || fail "spawn-hook-handover: the parser read owner '$got' out of the hook fm-spawn.sh really wrote, expected first-occupant"
out=$(run_spawn "$case_dir" second-occupant "$slot" "$case_dir/project" --harness opencode); rc=$?
expect_code 0 "$rc" "spawn-hook-handover second spawn"$'\n'"--- output ---"$'\n'"$out"
assert_absent "$slot/.claude/settings.local.json" \
  "spawn-hook-handover: the previous occupant's claude hook survived the next spawn"
got=$(fm_turnend_artifact_task_id "$slot/.opencode/plugins/fm-turn-end.js")
[ "$got" = second-occupant ] \
  || fail "spawn-hook-handover: the new occupant's own hook reads as owner '$got', expected second-occupant"
pass "fm-spawn.sh: a real spawn sweeps the turn-end hook a real earlier spawn left in the slot"

# --- audit fixtures ---------------------------------------------------------

# (F) UNTRACKED asserts what the pool records SAY, so it may only be reported
# when a reader actually answered. Here neither can: `treehouse status` fails and
# the home's pool directory holds no treehouse-state.json, which is exactly the
# shape a box without those tools installed produces for every home at once. The
# audit is the diagnostic every home refusal names, so a definite fleet-wide
# false alarm there is worse than admitting it does not know.
unknown_dir="$TMP_ROOT/audit-unreadable"
mkdir -p "$unknown_dir/state" "$unknown_dir/data" "$unknown_dir/fakebin"
git init -q -b main "$unknown_dir/proj"
git -C "$unknown_dir/proj" commit -q --allow-empty -m baseline
mkdir -p "$unknown_dir/.treehouse/pool-z/1"
git -C "$unknown_dir/proj" worktree add -q --detach "$unknown_dir/.treehouse/pool-z/1/proj" main
cat > "$unknown_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = status ] && exit 1
exit 0
SH
chmod +x "$unknown_dir/fakebin/treehouse"
register_secondmate "$unknown_dir/data/secondmates.md" dictate "$unknown_dir/.treehouse/pool-z/1/proj"
out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$unknown_dir/state" \
  FM_DATA_OVERRIDE="$unknown_dir/data" PATH="$unknown_dir/fakebin:$PATH" \
  "$AUDIT" 2>&1); rc=$?
expect_code 1 "$rc" "audit-unreadable"
assert_contains "$out" "UNKNOWN: dictate" "unreadable pool state is reported as unknown"
assert_contains "$out" "pool state could not be read" "the UNKNOWN line says what could not be read"
assert_not_contains "$out" "UNTRACKED" \
  "unreadable pool state was reported as a definite untracked-slot claim"
pass "fm-leased-home-audit.sh: reports UNKNOWN, not UNTRACKED, when no pool reader answered"

if ! command -v jq >/dev/null 2>&1; then
  pass "fm-leased-home-audit.sh: lease cases skipped (jq not installed)"
  exit 0
fi

# Build a pool-shaped fixture: <case>/.treehouse/<pool>/<slot>/proj worktrees cut
# from <case>/proj, so the audit's backing-repo and pool-directory resolution both
# have something real to walk.
make_audit_case() {  # <name>
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/data" "$case_dir/fakebin"
  git init -q -b main "$case_dir/proj"
  git -C "$case_dir/proj" commit -q --allow-empty -m baseline
  printf '%s\n' "$case_dir"
}

# Add slot <n> of pool <pool> as a real worktree, and echo its path.
add_pool_slot() {  # <case-dir> <pool> <n>
  local case_dir=$1 pool=$2 n=$3 path
  path="$case_dir/.treehouse/$pool/$n/proj"
  mkdir -p "$(dirname "$path")"
  git -C "$case_dir/proj" worktree add -q --detach "$path" main
  printf '%s\n' "$path"
}

# Write the pool's own durable records, one "<n> <leased-holder-or-->" per arg.
write_pool_state() {  # <case-dir> <pool> <entry>...
  local case_dir=$1 pool=$2 entry n holder first=1 out
  shift 2
  out="$case_dir/.treehouse/$pool/treehouse-state.json"
  printf '{"worktrees":[' > "$out"
  for entry in "$@"; do
    n=${entry%% *}
    holder=${entry##* }
    [ "$first" = 1 ] || printf ',' >> "$out"
    first=0
    if [ "$holder" = "-" ]; then
      printf '{"name":"%s","path":"%s"}' "$n" "$case_dir/.treehouse/$pool/$n/proj" >> "$out"
    else
      printf '{"name":"%s","path":"%s","leased":true,"lease_holder":"%s"}' \
        "$n" "$case_dir/.treehouse/$pool/$n/proj" "$holder" >> "$out"
    fi
  done
  printf ']}\n' >> "$out"
}

# `treehouse status --json` answers only for the pool named here, mirroring the
# real binary, which reports the one pool the backing repo resolves to today.
fake_treehouse_status() {  # <case-dir> <pool-or-empty> <status-entry>...
  local case_dir=$1 pool=$2 entry n status holder first=1 json=""
  shift 2
  if [ -n "$pool" ]; then
    for entry in "$@"; do
      n=${entry%% *}
      status=$(printf '%s' "$entry" | cut -d' ' -f2)
      holder=${entry##* }
      [ "$first" = 1 ] || json="$json,"
      first=0
      json="$json{\"name\":\"$n\",\"path\":\"$case_dir/.treehouse/$pool/$n/proj\""
      json="$json,\"status\":\"$status\",\"lease_holder\":\"$holder\"}"
    done
  fi
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = status ]; then
  printf '%s\n' '[$json]'
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

run_audit() {  # <case-dir> [args...]
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  PATH="$case_dir/fakebin:$PATH" \
    "$AUDIT" "$@"
}

# (f) Leased to its own id: clean.
case_dir=$(make_audit_case leased-ok)
home=$(add_pool_slot "$case_dir" pool-a 1)
write_pool_state "$case_dir" pool-a "1 dictate"
fake_treehouse_status "$case_dir" pool-a "1 leased dictate"
register_secondmate "$case_dir/data/secondmates.md" dictate "$home"
out=$(run_audit "$case_dir" 2>&1); rc=$?
expect_code 0 "$rc" "leased-ok audit"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "OK: dictate" "leased-ok reports the home as protected"
pass "fm-leased-home-audit.sh: a home leased to its own secondmate is clean"

# (g) In the pool, no lease: exactly what lets an ordinary acquisition take it.
case_dir=$(make_audit_case lease-lost)
home=$(add_pool_slot "$case_dir" pool-a 1)
write_pool_state "$case_dir" pool-a "1 -"
fake_treehouse_status "$case_dir" pool-a "1 in-use "
register_secondmate "$case_dir/data/secondmates.md" dictate "$home"
out=$(run_audit "$case_dir" 2>&1); rc=$?
expect_code 1 "$rc" "lease-lost audit"
assert_contains "$out" "LOST_LEASE: dictate" "lease-lost reports the unprotected home"
pass "fm-leased-home-audit.sh: reports a registered home that has lost its lease"

# (h) Leased, but to somebody else.
case_dir=$(make_audit_case holder-mismatch)
home=$(add_pool_slot "$case_dir" pool-a 1)
write_pool_state "$case_dir" pool-a "1 someoneelse"
fake_treehouse_status "$case_dir" pool-a "1 leased someoneelse"
register_secondmate "$case_dir/data/secondmates.md" dictate "$home"
out=$(run_audit "$case_dir" 2>&1); rc=$?
expect_code 1 "$rc" "holder-mismatch audit"
assert_contains "$out" "HOLDER_MISMATCH: dictate" "holder-mismatch is reported"
pass "fm-leased-home-audit.sh: reports a home leased to a different secondmate"

# (i) A home in a pool the live listing cannot see must be judged from that pool's
# own records, never reported as an unpooled home with no lease to lose.
case_dir=$(make_audit_case other-pool)
home=$(add_pool_slot "$case_dir" pool-b 3)
write_pool_state "$case_dir" pool-b "3 explore"
fake_treehouse_status "$case_dir" ""
register_secondmate "$case_dir/data/secondmates.md" explore "$home"
out=$(run_audit "$case_dir" 2>&1); rc=$?
expect_code 0 "$rc" "other-pool audit"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "OK: explore" "other-pool home is judged from its own pool records"
assert_not_contains "$out" "not pooled" "a real pool worktree is never called unpooled"
pass "fm-leased-home-audit.sh: judges a home in a pool the live listing cannot see"

# (j) A pool worktree that no pool has a record of can have its slot reallocated.
case_dir=$(make_audit_case untracked)
home=$(add_pool_slot "$case_dir" pool-b 4)
write_pool_state "$case_dir" pool-b "3 explore"
fake_treehouse_status "$case_dir" ""
register_secondmate "$case_dir/data/secondmates.md" herdr "$home"
out=$(run_audit "$case_dir" 2>&1); rc=$?
expect_code 1 "$rc" "untracked audit"
assert_contains "$out" "UNTRACKED: herdr" "an unrecorded pool worktree is reported"
pass "fm-leased-home-audit.sh: reports a pool worktree its pool has no record of"

# (k) A task already recorded inside another agent's home is a live collision.
case_dir=$(make_audit_case collision)
home=$(add_pool_slot "$case_dir" pool-a 1)
write_pool_state "$case_dir" pool-a "1 dictate"
fake_treehouse_status "$case_dir" pool-a "1 leased dictate"
register_secondmate "$case_dir/data/secondmates.md" dictate "$home"
fm_write_meta "$case_dir/state/scout-task.meta" \
  "window=firstmate:fm-scout-task" "endpoint_task_id=scout-task" \
  "worktree=$home" "project=$case_dir/proj" "harness=echo" "kind=scout"
out=$(run_audit "$case_dir" 2>&1); rc=$?
expect_code 1 "$rc" "collision audit"
assert_contains "$out" "COLLISION: task scout-task" "an occupied home is reported"
pass "fm-leased-home-audit.sh: reports a task already recorded inside a home"

# (J) The pool's own state file is read with jq, and jq does not report "this
# file lists no such home" and "I could not read this file" the same way: a valid
# file with no matching entry is a real answer, but a file caught mid-write by
# treehouse, or one whose schema moved on, is an error. Reporting the second as
# UNTRACKED would assert a fact about pool state the audit never read - on the
# one diagnostic every home refusal points operators at.
case_dir=$(make_audit_case pool-state-unreadable)
home=$(add_pool_slot "$case_dir" pool-a 1)
printf '%s\n' '{"schema":"moved-on"}' > "$case_dir/.treehouse/pool-a/treehouse-state.json"
cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = status ] && exit 1
exit 0
SH
chmod +x "$case_dir/fakebin/treehouse"
register_secondmate "$case_dir/data/secondmates.md" dictate "$home"
out=$(run_audit "$case_dir" 2>&1); rc=$?
expect_code 1 "$rc" "pool-state-unreadable audit"
assert_contains "$out" "UNKNOWN: dictate" "a state file that errors on read is reported as unknown"
assert_not_contains "$out" "UNTRACKED" \
  "an unreadable state file was reported as a definite untracked-slot claim"
pass "fm-leased-home-audit.sh: a pool state file that errors on read is UNKNOWN, not UNTRACKED"

# (l) A home seeded at an explicit path is a plain clone with no lease to lose.
case_dir=$(make_audit_case plain-clone)
git clone -q "$case_dir/proj" "$case_dir/clone-home"
fake_treehouse_status "$case_dir" ""
register_secondmate "$case_dir/data/secondmates.md" oktacorpus "$case_dir/clone-home"
out=$(run_audit "$case_dir" 2>&1); rc=$?
expect_code 0 "$rc" "plain-clone audit"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "not pooled" "a cloned home is reported as unpooled"
pass "fm-leased-home-audit.sh: a cloned home has no lease to lose"
