#!/usr/bin/env bash
# tests/fm-secondmate-standalone-owner-e2e.test.sh - mandatory ISOLATED
# end-to-end real-herdr test for the standalone-clone secondmate owner tag.
# Drives the REAL bin/fm-spawn.sh, because the requirement under test - a
# --secondmate spawn tagging its own workspace so herdr can nest a home whose
# checkout gives herdr no parentage signal - only exists at fm-spawn.sh's own
# post-metadata publish step, and the proof has to be the token herdr itself
# reports back, not anything the publisher printed.
#
# Herdr isolation: every lifecycle call and every Herdr query this test makes
# for itself goes through bin/fm-herdr-lab.sh - `name` for the session,
# `provision` for the server, `run` for each query, `teardown` for cleanup -
# which appends the required trailing --session, re-checks refuse-default
# immediately before each destructive call, and verifies the live default
# session is unchanged afterward. This file never invokes `herdr` directly.
# The one Herdr caller here that is not routed through the helper is
# fm-spawn.sh itself, which is the code under test: its adapter always appends
# its own trailing --session (bin/backends/herdr.sh's fm_backend_herdr_cli),
# and HERDR_SESSION below is what points it at this lab session rather than the
# captain's default one.
#
# Covers:
#   - a secondmate home that is a STANDALONE CLONE (its own git dir) is spawned
#     by the primary and its workspace carries owner=firstmate, read back from
#     herdr's own `workspace list`
#   - a secondmate home that is a LINKED WORKTREE is spawned the same way and
#     its workspace carries NO owner token at all - the free-parentage path is
#     untouched
#   - the tag CONVERGES: clearing the token and respawning the same secondmate
#     republishes it, so the fix is not a one-time hand-applied fact
#
# The "no expiry" half of the durability guarantee is NOT asserted here: the
# installed herdr CLI exposes tokens through `workspace list` but never their
# remaining lifetime, so there is nothing to read back. It is asserted where
# the actual argument vector IS observable - the no `--ttl-ms` case in
# tests/fm-herdr-owner-publish.test.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found (required to build the checkouts under test)"; exit 0; }

# Sourced for FM_GATE_REFUSE_BYPASS, which every real-herdr test in this suite
# needs; the lab contract itself is exercised through the helper SCRIPT below.
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name secondmate-standalone-owner-tag) \
  || { echo "skip: could not generate a lab session name"; exit 0; }
export HERDR_SESSION="$HERDR_LAB_SESSION"

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-sm-owner-e2e.XXXXXX")

# Idempotent: fail() exits and lets this trap do the cleanup, so teardown runs
# exactly once even on an early failure.
CLEANED=0
cleanup_all() {
  [ "$CLEANED" -eq 0 ] || return 0
  CLEANED=1
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
}
# Armed BEFORE provisioning, so a session created by a provision that then
# fails partway is still torn down.
trap cleanup_all EXIT

"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr lab session '$HERDR_LAB_SESSION'"

# Every Herdr call this test makes for itself. The helper appends the trailing
# --session and refuses a caller-supplied one.
lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

git_quiet() { git -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "$@"; }

# --- scratch world --------------------------------------------------------

PRIMARY_HOME="$TMP_ROOT/primary-home"
mkdir -p "$PRIMARY_HOME/state" "$PRIMARY_HOME/data" "$PRIMARY_HOME/config"

# The shared repository the LINKED secondmate home will be a worktree of. The
# STANDALONE home is a repository in its own right, which is exactly the
# difference under test.
UPSTREAM="$TMP_ROOT/upstream-repo"
mkdir -p "$UPSTREAM"
git_quiet -C "$UPSTREAM" init -q
printf '# scratch upstream\n' > "$UPSTREAM/README.md"
git_quiet -C "$UPSTREAM" add README.md
git_quiet -C "$UPSTREAM" commit -qm initial

# Give a scratch directory the shape fm-spawn.sh validates a secondmate home by.
dress_secondmate_home() {  # <home> <id>
  local home=$1 id=$2
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$home/bin"
  printf '# scratch secondmate home AGENTS.md placeholder\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'trivial e2e secondmate charter: nothing to do.\n' > "$home/data/charter.md"
}

STAND_HOME="$TMP_ROOT/sm-standalone"
mkdir -p "$STAND_HOME"
git_quiet -C "$STAND_HOME" init -q
printf '# scratch standalone home\n' > "$STAND_HOME/README.md"
git_quiet -C "$STAND_HOME" add README.md
git_quiet -C "$STAND_HOME" commit -qm initial
dress_secondmate_home "$STAND_HOME" e2estand
[ -d "$STAND_HOME/.git" ] || fail "fixture error: the standalone home should own a real .git directory"

LINKED_HOME="$TMP_ROOT/sm-linked"
git_quiet -C "$UPSTREAM" worktree add -q -b e2e-linked "$LINKED_HOME" >/dev/null 2>&1 \
  || fail "fixture error: could not create a linked worktree home"
dress_secondmate_home "$LINKED_HOME" e2elinked
[ -f "$LINKED_HOME/.git" ] || fail "fixture error: the linked home should carry a .git FILE, not a directory"

# --- helpers reading herdr's own view -------------------------------------

spawn_secondmate() {  # <id> <home>
  local id=$1 home=$2 rc
  set +e
  FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$home" "sh -c 'echo secondmate-launch-ok'" \
    --secondmate --backend herdr \
    >"$TMP_ROOT/$id.out" 2>"$TMP_ROOT/$id.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "--secondmate spawn of $id failed"$'\n'"--- stdout ---"$'\n'"$(cat "$TMP_ROOT/$id.out")"$'\n'"--- stderr ---"$'\n'"$(cat "$TMP_ROOT/$id.err")"
}

meta_field() {  # <id> <key>
  grep "^$2=" "$PRIMARY_HOME/state/$1.meta" | cut -d= -f2-
}

workspace_owner_token() {  # <workspace-id> -> the owner token value, or empty
  lab workspace list 2>/dev/null \
    | jq -r --arg id "$1" '.result.workspaces[]? | select(.workspace_id == $id) | .tokens.owner // empty'
}

# --- 1. the standalone-clone secondmate is tagged -------------------------

spawn_secondmate e2estand "$STAND_HOME"
STAND_WS=$(meta_field e2estand herdr_workspace_id)
STAND_PANE=$(meta_field e2estand herdr_pane_id)
[ -n "$STAND_WS" ] || fail "e2estand meta recorded no herdr workspace"
[ "$(meta_field e2estand home)" = "$STAND_HOME" ] || fail "e2estand meta did not record its own home"
pass "real herdr E2E: the primary spawns a standalone-clone secondmate on the herdr backend"

STAND_OWNER=$(workspace_owner_token "$STAND_WS")
[ "$STAND_OWNER" = firstmate ] \
  || fail "a standalone-clone secondmate's workspace should carry owner=firstmate, got '${STAND_OWNER:-<none>}'"
pass "real herdr E2E: a real spawn tags a standalone-clone secondmate's workspace with owner=firstmate"

# --- 2. the linked-worktree secondmate is left completely alone -----------

spawn_secondmate e2elinked "$LINKED_HOME"
LINKED_WS=$(meta_field e2elinked herdr_workspace_id)
LINKED_PANE=$(meta_field e2elinked herdr_pane_id)
[ -n "$LINKED_WS" ] || fail "e2elinked meta recorded no herdr workspace"
[ "$LINKED_WS" != "$STAND_WS" ] || fail "the two secondmates must not share one workspace"
pass "real herdr E2E: the primary spawns a linked-worktree secondmate into its own workspace"

LINKED_OWNER=$(workspace_owner_token "$LINKED_WS")
[ -z "$LINKED_OWNER" ] \
  || fail "a linked-worktree secondmate's workspace must carry NO owner token - herdr already derives its parentage - but it carries '$LINKED_OWNER'"
pass "real herdr E2E: a linked-worktree secondmate's workspace is untouched, carrying no owner token"

# --- 3. the tag converges on every relaunch --------------------------------
# Clear the token the way an expiry or a herdr-side reset would, drop the
# task's durable record, and relaunch the SAME secondmate home into the SAME
# workspace. A one-time hand-applied fact would stay cleared; a spawn-time
# publish comes back.
#
# The relaunch has to find the workspace still there, and closing a herdr
# workspace's last tab deletes the workspace itself (see
# fm_backend_herdr_workspace_ensure's notes). Hold it open with an ordinary
# scratch tab - test scaffolding standing in for the real case, where the home
# has other task tabs - so this exercises ADOPTING an existing space rather
# than trivially tagging a brand-new one. Its label must not collide with the
# task tab's, which fm_backend_herdr_create_task refuses to duplicate.
HOLDER_TAB=$(lab tab create --workspace "$STAND_WS" --cwd "$TMP_ROOT" --label e2e-holder --no-focus 2>/dev/null \
  | jq -r '.result.tab.tab_id // empty')
[ -n "$HOLDER_TAB" ] || fail "could not open a holder tab to keep workspace $STAND_WS alive across the relaunch"

lab workspace report-metadata "$STAND_WS" --source firstmate --clear-token owner >/dev/null 2>&1 || true
[ -z "$(workspace_owner_token "$STAND_WS")" ] || fail "the owner token should be gone after an explicit clear"

lab pane close "$STAND_PANE" >/dev/null 2>&1 || true
rm -f "$PRIMARY_HOME/state/e2estand.meta"

spawn_secondmate e2estand "$STAND_HOME"
RESPAWN_WS=$(meta_field e2estand herdr_workspace_id)
[ "$RESPAWN_WS" = "$STAND_WS" ] \
  || fail "the relaunched secondmate should adopt its own existing workspace $STAND_WS, got '$RESPAWN_WS'"
RESPAWN_OWNER=$(workspace_owner_token "$STAND_WS")
[ "$RESPAWN_OWNER" = firstmate ] \
  || fail "relaunching a standalone-clone secondmate must republish owner=firstmate into its existing workspace, got '${RESPAWN_OWNER:-<none>}'"
pass "real herdr E2E: the owner tag is republished into the same workspace on relaunch, not applied once by hand"

lab tab close "$HOLDER_TAB" >/dev/null 2>&1 || true
lab pane close "$(meta_field e2estand herdr_pane_id)" >/dev/null 2>&1 || true
lab pane close "$LINKED_PANE" >/dev/null 2>&1 || true

cleanup_all
trap - EXIT
