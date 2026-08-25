#!/usr/bin/env bash
# tests/fm-backend-herdr-space-grouping-e2e.test.sh - mandatory ISOLATED
# end-to-end real-herdr test for worktree-BACKED home spaces and the worker
# `owner` metadata token.
#
# Real herdr, not a fake, because the property under test is one herdr itself
# computes: a workspace created through `workspace create` carries a null
# worktree block no matter what its cwd is, so herdr's sidebar (which groups
# workspaces by repo key and indents every member whose worktree is linked)
# can never group it. Only a workspace created through herdr's WORKTREE path
# carries the membership that makes a secondmate home render indented under the
# primary home. No fake can stand in for that.
#
# The fixture is therefore shaped like the real fleet and unlike
# tests/fm-backend-herdr-workspace-per-home-e2e.test.sh's plain scratch dirs:
# the primary home is a repository's MAIN checkout and the secondmate home is a
# LINKED worktree of it, exactly as every real secondmate home is a linked
# worktree of the firstmate repo.
#
# Covers:
#   - a secondmate home spawned by the primary gets a worktree-backed space:
#     populated worktree block, is_linked_worktree true, repo_root naming the
#     primary home
#   - the primary home's own space becomes the un-indented repo parent
#     (same repo key, is_linked_worktree false), so the two group
#   - space lookup by label still resolves both homes (the mechanism
#     fm-spawn.sh resolves every worker placement through)
#   - a worker pane carries owner=<calling mate>, and a secondmate pane
#     carries no owner token at all
#   - adoption discipline: a workspace already open on a home's checkout keeps
#     its own name and the home still gets its own labelled space
#   - the no-parent guard: with no space open on the repo's main checkout,
#     the spawn falls back to a flat space and does NOT let herdr invent a
#     stray parent workspace labelled from the repo directory basename
#
# Safety (2026-07-02 incident, see tests/herdr-test-safety.sh): private
# throwaway sessions, never the captain's default, and cleanup only through
# herdr_safe_stop_and_delete.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-grouping-e2e.XXXXXX")
SESSION_MAIN="fm-lab-herdr-group-$$"
SESSION_GUARD="fm-lab-herdr-guard-$$"
WT1=
cleanup_all() {
  [ -n "$WT1" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT1" >/dev/null 2>&1
  herdr_safe_stop_and_delete "$SESSION_MAIN" >/dev/null 2>&1
  herdr_safe_stop_and_delete "$SESSION_GUARD" >/dev/null 2>&1
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT

# --- scratch world -----------------------------------------------------------
# The repo directory is deliberately NAMED "firstmate": herdr labels a
# workspace it invents itself from the repo directory's basename, so a stray
# parent here would carry the exact label the primary home's own space uses.
# That collision is the failure the no-parent guard exists to prevent, and
# naming the fixture this way is what makes the guard assertion meaningful.
PRIMARY_HOME="$TMP_ROOT/firstmate"
mkdir -p "$PRIMARY_HOME"
git -C "$PRIMARY_HOME" init -q
printf '# scratch firstmate-shaped repo\n' > "$PRIMARY_HOME/README.md"
git -C "$PRIMARY_HOME" add README.md
git -C "$PRIMARY_HOME" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
mkdir -p "$PRIMARY_HOME/state" "$PRIMARY_HOME/data/cm1" "$PRIMARY_HOME/config"
printf 'trivial e2e primary crewmate brief: nothing to do.\n' > "$PRIMARY_HOME/data/cm1/brief.md"

# The secondmate home: a LINKED worktree of the primary home, the real shape.
SM_HOME="$TMP_ROOT/sm-home"
git -C "$PRIMARY_HOME" worktree add -q -b e2e-sm "$SM_HOME"
mkdir -p "$SM_HOME/state" "$SM_HOME/data" "$SM_HOME/config" "$SM_HOME/projects" "$SM_HOME/bin"
printf '# scratch secondmate home AGENTS.md placeholder\n' > "$SM_HOME/AGENTS.md"
printf 'e2egrp1\n' > "$SM_HOME/.fm-secondmate-home"
printf 'trivial e2e secondmate charter: nothing to do.\n' > "$SM_HOME/data/charter.md"

make_scratch_project() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# scratch\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}
PROJ1="$TMP_ROOT/scratch-project-1"; make_scratch_project "$PROJ1"

# NOTE: no `// empty` alternative here. jq's `//` treats `false` as absent, so
# it would silently turn the is_linked_worktree=false the parent assertion
# depends on into an empty string. An absent field prints as "null" instead.
ws_field() {  # <session> <workspace_id> <jq-path>
  herdr workspace list --session "$1" 2>/dev/null \
    | jq -r --arg id "$2" ".result.workspaces[]? | select(.workspace_id == \$id) | $3"
}
ws_id_for_label() {  # <session> <label>
  herdr workspace list --session "$1" 2>/dev/null \
    | jq -r --arg want "$2" '.result.workspaces[]? | select(.label == $want) | .workspace_id' | head -1
}
ws_count_for_label() {  # <session> <label>
  herdr workspace list --session "$1" 2>/dev/null \
    | jq -r --arg want "$2" '[.result.workspaces[]? | select(.label == $want)] | length'
}
pane_owner_token() {  # <session> <pane_id>
  herdr pane get "$2" --session "$1" 2>/dev/null | jq -r '.result.pane.tokens.owner // empty'
}

# --- part 1: the no-parent guard, in its own session -------------------------
# Nothing is open on the repo's main checkout, so herdr would invent a parent
# workspace at the repo root if given only a cwd. The adapter must instead fall
# back to a flat space and leave the workspace list free of any stray parent.

export HERDR_SESSION="$SESSION_GUARD"
fm_herdr_lab_prepare "$SESSION_GUARD" || fail "could not prepare the isolated guard lab session"

GUARD_OUT="$TMP_ROOT/guard.out"; GUARD_ERR="$TMP_ROOT/guard.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" e2egrp1 "$SM_HOME" "sh -c 'echo guard-sm-ok'" --secondmate --backend herdr \
  >"$GUARD_OUT" 2>"$GUARD_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "the guard-scenario --secondmate spawn failed"$'\n'"--- stdout ---"$'\n'"$(cat "$GUARD_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$GUARD_ERR")"

GUARD_PANE=$(grep '^herdr_pane_id=' "$PRIMARY_HOME/state/e2egrp1.meta" | cut -d= -f2-)
[ -n "$GUARD_PANE" ] || fail "guard-scenario secondmate meta missing herdr_pane_id"
GUARD_WSID=$(herdr pane get "$GUARD_PANE" --session "$SESSION_GUARD" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$GUARD_WSID" ] || fail "could not read the guard-scenario secondmate's workspace_id"
[ "$(ws_field "$SESSION_GUARD" "$GUARD_WSID" .label)" = "2ndmate-e2egrp1" ] \
  || fail "the guard-scenario secondmate should still get its own labelled space"
# Whether the fallback space's .worktree field itself reads null is
# client-version-dependent (newer herdr clients populate a worktree block even
# on a plain create) and not what this guard protects. The safety property is
# that no stray parent workspace gets invented and labelled from the repo
# directory's basename, colliding with the primary home's own "firstmate"
# label - asserted by the two checks below.
[ "$(ws_count_for_label "$SESSION_GUARD" firstmate)" = "0" ] \
  || fail "the guard must not let herdr invent a parent workspace labelled from the repo directory basename ('firstmate')"
[ "$(herdr workspace list --session "$SESSION_GUARD" 2>/dev/null | jq -r '.result.workspaces | length')" = "1" ] \
  || fail "the guard scenario must leave exactly one workspace - the secondmate's own"
pass "real herdr E2E: with no space open on the repo parent, a secondmate spawn falls back flat and invents no stray parent workspace"

herdr_safe_stop_and_delete "$SESSION_GUARD" >/dev/null 2>&1
rm -f "$PRIMARY_HOME/state/e2egrp1.meta"

# --- part 2: the grouping happy path -----------------------------------------

export HERDR_SESSION="$SESSION_MAIN"
fm_herdr_lab_prepare "$SESSION_MAIN" || fail "could not prepare the isolated grouping lab session"

# The primary home spawns a crewmate first, which is what opens the primary
# home's own space - anchored at the home, i.e. the repo's main checkout.
CM1_OUT="$TMP_ROOT/cm1.out"; CM1_ERR="$TMP_ROOT/cm1.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" cm1 "$PROJ1" "sh -c 'echo primary-crew-ok'" --mode no-mistakes --yolo off --backend herdr \
  >"$CM1_OUT" 2>"$CM1_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "the primary-shaped crewmate spawn failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM1_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM1_ERR")"
WT1=$(grep '^worktree=' "$PRIMARY_HOME/state/cm1.meta" | cut -d= -f2-)
CM1_PANE=$(grep '^herdr_pane_id=' "$PRIMARY_HOME/state/cm1.meta" | cut -d= -f2-)
[ -n "$CM1_PANE" ] || fail "cm1 meta missing herdr_pane_id"
PRIMARY_WSID=$(herdr pane get "$CM1_PANE" --session "$SESSION_MAIN" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ "$(ws_field "$SESSION_MAIN" "$PRIMARY_WSID" .label)" = "firstmate" ] \
  || fail "the primary home's crewmate should land in the 'firstmate' space"
pass "real herdr E2E: the primary home's space opens anchored at the home itself"

# Now the secondmate, whose home is a linked worktree of that same repo.
SM_OUT="$TMP_ROOT/sm.out"; SM_ERR="$TMP_ROOT/sm.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" e2egrp1 "$SM_HOME" "sh -c 'echo grouped-sm-ok'" --secondmate --backend herdr \
  >"$SM_OUT" 2>"$SM_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "the --secondmate spawn failed"$'\n'"--- stdout ---"$'\n'"$(cat "$SM_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$SM_ERR")"
SM_PANE=$(grep '^herdr_pane_id=' "$PRIMARY_HOME/state/e2egrp1.meta" | cut -d= -f2-)
[ -n "$SM_PANE" ] || fail "e2egrp1 meta missing herdr_pane_id"
SM_WSID=$(herdr pane get "$SM_PANE" --session "$SESSION_MAIN" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$SM_WSID" ] || fail "could not read the secondmate's workspace_id"
[ "$SM_WSID" != "$PRIMARY_WSID" ] || fail "the secondmate must get its own space, not the primary's"

# The requirement itself: the child space is worktree-backed and linked.
[ "$(ws_field "$SESSION_MAIN" "$SM_WSID" .worktree.is_linked_worktree)" = "true" ] \
  || fail "the secondmate's space must carry a worktree block with is_linked_worktree true, or herdr's sidebar can never indent it"
PRIMARY_REAL=$(cd "$PRIMARY_HOME" && pwd -P)
SM_REPO_ROOT=$(ws_field "$SESSION_MAIN" "$SM_WSID" .worktree.repo_root)
[ "$(cd "$SM_REPO_ROOT" && pwd -P)" = "$PRIMARY_REAL" ] \
  || fail "the secondmate space's repo_root should name the primary home, got '$SM_REPO_ROOT'"
pass "real herdr E2E: a secondmate home gets a worktree-backed space naming the primary home as its repo parent"

# The parent side of the same grouping: same repo key, not linked.
[ "$(ws_field "$SESSION_MAIN" "$PRIMARY_WSID" .worktree.is_linked_worktree)" = "false" ] \
  || fail "the primary home's space must be the un-indented parent: worktree present, is_linked_worktree false"
SM_KEY=$(ws_field "$SESSION_MAIN" "$SM_WSID" .worktree.repo_key)
PRIMARY_KEY=$(ws_field "$SESSION_MAIN" "$PRIMARY_WSID" .worktree.repo_key)
[ -n "$SM_KEY" ] && [ "$SM_KEY" = "$PRIMARY_KEY" ] \
  || fail "both spaces must share one repo key for herdr to group them, got parent='$PRIMARY_KEY' child='$SM_KEY'"
pass "real herdr E2E: the primary and secondmate spaces share one repo key with exactly one un-indented parent - herdr's grouping precondition"

# Constraint: space lookup by label, which every worker placement goes through.
[ "$(ws_id_for_label "$SESSION_MAIN" firstmate)" = "$PRIMARY_WSID" ] \
  || fail "lookup of the 'firstmate' space by label must still resolve the primary home's space"
[ "$(ws_id_for_label "$SESSION_MAIN" 2ndmate-e2egrp1)" = "$SM_WSID" ] \
  || fail "lookup of the '2ndmate-<id>' space by label must still resolve the secondmate's space"
[ "$(ws_count_for_label "$SESSION_MAIN" firstmate)" = "1" ] \
  || fail "there must be exactly one space labelled 'firstmate'"
pass "real herdr E2E: space lookup by label still resolves both homes to exactly the right space"

# --- part 3: the worker owner token ------------------------------------------

[ "$(pane_owner_token "$SESSION_MAIN" "$CM1_PANE")" = "firstmate" ] \
  || fail "a worker spawned by the primary must carry owner=firstmate, got '$(pane_owner_token "$SESSION_MAIN" "$CM1_PANE")'"
[ -z "$(pane_owner_token "$SESSION_MAIN" "$SM_PANE")" ] \
  || fail "a secondmate is a mate, not a worker: its pane must carry no owner token, got '$(pane_owner_token "$SESSION_MAIN" "$SM_PANE")'"
pass "real herdr E2E: a worker pane is stamped with its calling mate's moniker and a secondmate pane is left unstamped"

# A worker spawned FROM the secondmate home carries that secondmate's moniker.
mkdir -p "$SM_HOME/data/cm2"
printf 'trivial e2e secondmate-owned crewmate brief: nothing to do.\n' > "$SM_HOME/data/cm2/brief.md"
CM2_OUT="$TMP_ROOT/cm2.out"; CM2_ERR="$TMP_ROOT/cm2.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$SM_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" cm2 "$PROJ1" "sh -c 'echo sm-crew-ok'" --mode no-mistakes --yolo off --backend herdr \
  >"$CM2_OUT" 2>"$CM2_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "a crewmate spawned FROM the secondmate home failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM2_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM2_ERR")"
CM2_PANE=$(grep '^herdr_pane_id=' "$SM_HOME/state/cm2.meta" | cut -d= -f2-)
CM2_WT=$(grep '^worktree=' "$SM_HOME/state/cm2.meta" | cut -d= -f2-)
[ "$(pane_owner_token "$SESSION_MAIN" "$CM2_PANE")" = "2ndmate-e2egrp1" ] \
  || fail "a worker spawned by the secondmate must carry that secondmate's moniker, got '$(pane_owner_token "$SESSION_MAIN" "$CM2_PANE")'"
CM2_WSID=$(herdr pane get "$CM2_PANE" --session "$SESSION_MAIN" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ "$CM2_WSID" = "$SM_WSID" ] \
  || fail "a worker spawned FROM the secondmate home must land in the secondmate's own space"
pass "real herdr E2E: a worker spawned by a secondmate is stamped with that secondmate's moniker and lands in its space"

[ -n "$CM2_WT" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$CM2_WT" >/dev/null 2>&1

# --- part 4: adoption never renames a workspace firstmate did not create -----
# Herdr reuses ANY workspace already open on the exact checkout a home sits on,
# including one opened by hand. Firstmate must leave that workspace's own name
# alone and mint its own labelled space instead of relabelling it.

SM2_HOME="$TMP_ROOT/sm-home-2"
git -C "$PRIMARY_HOME" worktree add -q -b e2e-sm2 "$SM2_HOME"
mkdir -p "$SM2_HOME/state" "$SM2_HOME/data" "$SM2_HOME/config" "$SM2_HOME/projects" "$SM2_HOME/bin"
printf '# scratch secondmate home AGENTS.md placeholder\n' > "$SM2_HOME/AGENTS.md"
printf 'e2egrp2\n' > "$SM2_HOME/.fm-secondmate-home"
printf 'trivial e2e secondmate charter: nothing to do.\n' > "$SM2_HOME/data/charter.md"

FOREIGN_WSID=$(herdr worktree open --workspace "$PRIMARY_WSID" --path "$SM2_HOME" --no-focus --session "$SESSION_MAIN" 2>/dev/null \
  | jq -r '.result.workspace.workspace_id // empty')
[ -n "$FOREIGN_WSID" ] || fail "could not open the by-hand workspace the adoption fixture needs"
herdr workspace rename "$FOREIGN_WSID" captains-own --session "$SESSION_MAIN" >/dev/null 2>&1 \
  || fail "could not name the by-hand workspace"

SM2_OUT="$TMP_ROOT/sm2.out"; SM2_ERR="$TMP_ROOT/sm2.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" e2egrp2 "$SM2_HOME" "sh -c 'echo adopt-sm-ok'" --secondmate --backend herdr \
  >"$SM2_OUT" 2>"$SM2_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "the adoption-scenario --secondmate spawn failed"$'\n'"--- stdout ---"$'\n'"$(cat "$SM2_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$SM2_ERR")"
[ "$(ws_field "$SESSION_MAIN" "$FOREIGN_WSID" .label)" = "captains-own" ] \
  || fail "a workspace firstmate did not create must keep its own name, got '$(ws_field "$SESSION_MAIN" "$FOREIGN_WSID" .label)'"
SM2_PANE=$(grep '^herdr_pane_id=' "$PRIMARY_HOME/state/e2egrp2.meta" | cut -d= -f2-)
SM2_WSID=$(herdr pane get "$SM2_PANE" --session "$SESSION_MAIN" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$SM2_WSID" ] && [ "$SM2_WSID" != "$FOREIGN_WSID" ] \
  || fail "the secondmate must get its own space rather than taking over the by-hand one"
[ "$(ws_id_for_label "$SESSION_MAIN" 2ndmate-e2egrp2)" = "$SM2_WSID" ] \
  || fail "label lookup must still resolve the secondmate's own space in the adoption scenario"
pass "real herdr E2E: a workspace already open on a home checkout keeps its own name and the home still gets its own labelled space"

cleanup_all
trap - EXIT
printf 'ok - real Herdr space-grouping validation completed with the default-session tripwire intact\n'
