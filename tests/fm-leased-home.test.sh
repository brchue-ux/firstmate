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
case_dir=$(make_teardown_case forced-home dictate)
mark_secondmate_home "$case_dir/wt"
fm_write_meta "$case_dir/state/task-x1.meta" \
  "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
  "worktree=$case_dir/wt" "project=$case_dir/project" \
  "harness=echo" "kind=ship" "yolo=off"
out=$(run_teardown "$case_dir" task-x1 --force 2>&1); rc=$?
expect_code 1 "$rc" "forced-home teardown"
assert_contains "$out" "REFUSED" "--force still refuses a secondmate home"
assert_no_return_ran "$case_dir" "forced-home"
assert_present "$case_dir/wt/.fm-secondmate-home" "forced-home: the home marker survived"
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

# --- audit fixtures ---------------------------------------------------------

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

# (l) A home seeded at an explicit path is a plain clone with no lease to lose.
case_dir=$(make_audit_case plain-clone)
git clone -q "$case_dir/proj" "$case_dir/clone-home"
fake_treehouse_status "$case_dir" ""
register_secondmate "$case_dir/data/secondmates.md" oktacorpus "$case_dir/clone-home"
out=$(run_audit "$case_dir" 2>&1); rc=$?
expect_code 0 "$rc" "plain-clone audit"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "not pooled" "a cloned home is reported as unpooled"
pass "fm-leased-home-audit.sh: a cloned home has no lease to lose"
