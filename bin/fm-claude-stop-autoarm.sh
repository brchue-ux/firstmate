#!/usr/bin/env bash
# Claude Stop-owned watcher auto-arm (asyncRewake hook).
#
# Registered in tracked .claude/settings.json as a Stop command hook with
# "asyncRewake": true and an explicit multi-hour timeout. Claude Code fires it
# in the background on EVERY Stop of a Claude primary session, with no
# deduplication across firings. It owns routine tokenless watcher continuity
# for Claude primaries (main home and marked secondmate homes):
#
#   - Scope: only a genuine primary checkout (plain checkout or validly marked
#     secondmate home) with AGENTS.md, bin/, and the effective state dir - the
#     exact fm-turnend-guard.sh scope. Child crew/scout worktrees stay inert.
#   - Identity: only when THIS session's harness ancestor holds state/.lock.
#     When an existing numeric owner fails the shared harness-liveness predicate,
#     the hook delegates guarded recovery to bin/fm-lock.sh and then re-verifies
#     ownership. A missing lock, malformed lock, or unresolved ancestry remains
#     inert. A LIVE owner also remains inert - a competing session never arms or
#     rewakes - with one proven exception: when the Stop payload's session id
#     matches this home's re-host record and that record still names the current
#     lock pid, the live owner is an earlier host process of THIS session
#     (bin/fm-session-lock-lib.sh, "session re-host record"), and the hook
#     re-anchors the lock through bin/fm-lock.sh --adopt-session. Without that
#     exception a re-hosted session reads as a competing one and this hook goes
#     silently inert for the rest of the session, leaving the home with no
#     watcher at all; docs/turnend-guard.md records the 2026-09-01 incident.
#   - AFK: while state/.afk exists the away daemon owns the watcher and triage;
#     this hook exits 0 and NEVER rewakes the primary (checked again at
#     translation time so a mid-cycle AFK transition is honored).
#   - Need: arms only while work is in flight (state/*.meta) or X mode has a
#     relay poll to run (state/x-watch.check.sh); an idle home exits 0.
#   - Single-flight: Claude does not dedupe async hooks, so a home-scoped owner
#     lock (state/.claude-autoarm.lock) admits exactly one owner; every other
#     concurrent firing exits 0 without translating, which keeps one event
#     epoch on exactly one recovery turn. Claimed before the stale-lock reclaim
#     below (not only before the foreground arm), so its pid file - one of the
#     synchronous guard's own "recovery already under way" signals - is visible
#     within milliseconds of this hook committing to work, rather than only
#     after the reclaim's extra subprocess and ancestry walk finish.
#   - Foreground arm: the owner runs bin/fm-watch-arm.sh in the FOREGROUND of
#     this hook-owned process tree (never shell &); Claude owns the process
#     group, so its timeout/session teardown kills arm and watcher together.
#   - Translation: while supervision is still needed and AFK remains inactive,
#     an actionable arm close (signal:/stale:/check:/heartbeat) or a typed
#     watcher: FAILED prints one rewake banner to stderr and exits 2, which
#     wakes Claude even while idle ("Stop hook feedback"). A clean close with
#     no actionable reason and no remaining need exits 0 silently.
#
# The epoch ledger state/.claude-autoarm-epoch records the latest claim and
# outcome so the synchronous Stop guard (bin/fm-turnend-guard.sh --claude) can
# allow a stop whose recovery this hook already owns, instead of forcing a
# duplicate continuation for the same event epoch.
#
# This hook never blocks the Stop decision itself and never prints to stdout:
# exit 0 is always silent, and exit 2 carries the rewake banner on stderr.
# On any uncertainty such as unresolvable ancestry, malformed lock state, or
# lock contention, it exits 0 and leaves continuity to the synchronous guard and
# the model.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# FM_HOME resolution: see bin/fm-home-anchor-lib.sh ("Why this exists").
# shellcheck source=bin/fm-home-anchor-lib.sh
. "$SCRIPT_DIR/fm-home-anchor-lib.sh"
fm_home_anchor_resolve "$FM_ROOT" quiet || exit 0
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
OWNER_LOCK="$STATE/.claude-autoarm.lock"
EPOCH="$STATE/.claude-autoarm-epoch"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

# Consume the Stop payload once, so a slow writer can never wedge on a full
# pipe. Every decision below is state-based except the re-host proof, which
# needs the payload's own session id. Without jq, or with an unusable id, that
# one proof is simply unavailable and the identity gate behaves as it always
# did - never more permissively.
PAYLOAD=$(cat 2>/dev/null || true)
SESSION_ID=
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  SESSION_ID=$(printf '%s' "$PAYLOAD" \
    | jq -r 'if type == "object" and ((.session_id | type) == "string") then .session_id else empty end' \
      2>/dev/null || true)
  fm_session_lock_id_valid "$SESSION_ID" || SESSION_ID=
fi

# --- scope: genuine primary checkout only -----------------------------------
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- identity: only the lock-owning session's hooks may arm ------------------
# A prior session may have died after leaving its numeric harness pid in .lock.
# Use the shared liveness predicate to recognize only that stale-owner case.
# Defer the mutating claim until after the unchanged AFK and need gates, so an
# idle or away home remains byte-for-byte inert. Missing or malformed locks are
# uncertainty rather than stale-owner evidence and remain inert.
RECOVER_SESSION_LOCK=0
ADOPT_SESSION=
if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$LOCK_PID" in
    ''|*[!0-9]*) exit 0 ;;
  esac
  if fm_harness_pid_alive "$LOCK_PID"; then
    if [ -n "$SESSION_ID" ] && fm_session_lock_rehost_proven "$STATE" "$SESSION_ID"; then
      ADOPT_SESSION=$SESSION_ID
    else
      exit 0
    fi
  fi
  RECOVER_SESSION_LOCK=1
fi

# --- AFK: the away daemon owns the watcher and triage; never rewake ----------
[ -e "$STATE/.afk" ] && exit 0

# --- need: in-flight work or an X-mode relay poll ----------------------------
need_supervision() {
  fm_supervision_needed "$STATE" "$GRACE"
}
need_supervision || exit 0

# --- single-flight owner claim ------------------------------------------------
# Claude runs one background process per firing with no dedupe. Exactly one
# owner foregrounds the arm and translates its close; every other firing exits
# 0 so one watcher cycle maps to at most one exit-2 rewake.
# Claimed here, before stale-lock recovery rather than after it, so the
# synchronous guard's "owner lock pid alive" check (bin/fm-turnend-guard.sh
# --claude, autoarm_owns_recovery) becomes true within milliseconds of this
# hook committing to work - not only after the reclaim (an extra fm-lock.sh
# subprocess plus a second harness-ancestry walk) finishes. The guard's fixed
# sync-wait budget has no other signal during that reclaim: measured live, it
# adds several hundred ms over the already-owned path, comfortably enough to
# blow the guard's default budget under real fleet load and force an
# unnecessary blind-turn block even though recovery was genuinely under way.
# A side benefit: two concurrent firings that both see a reclaimable stale
# lock no longer both pay for the reclaim - only the single-flight winner does.
fm_lock_try_acquire "$OWNER_LOCK" || exit 0
trap 'fm_lock_release "$OWNER_LOCK"' EXIT

# --- stale session-lock recovery ---------------------------------------------
# Delegate the claim to fm-lock.sh so its live-owner refusal and write semantics
# remain the single acquisition owner, then re-verify current-session identity
# before touching any auto-arm state.
if [ "$RECOVER_SESSION_LOCK" -eq 1 ]; then
  if [ -n "$ADOPT_SESSION" ]; then
    "$SCRIPT_DIR/fm-lock.sh" --adopt-session "$ADOPT_SESSION" >/dev/null 2>&1 || exit 0
  else
    "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || exit 0
  fi
  fm_session_lock_owned_by_self "$STATE" || exit 0
fi

# Ownership is verified for this firing, so record which session owns this home
# and at which harness pid. This is the only writer of that record on the
# ordinary path, and it refreshes on every owned firing, so a session id that
# changes while ancestry is intact - a compaction, for instance - is picked up
# within one turn end.
if [ -n "$SESSION_ID" ]; then
  fm_session_lock_record_owner "$STATE" "$SESSION_ID" \
    "$(cat "$STATE/.lock" 2>/dev/null || true)" || true
fi

write_epoch() {  # <outcome>
  local outcome=$1 seq tmp
  seq=$(sed -n 's/^epoch=\([0-9][0-9]*\) .*/\1/p' "$EPOCH" 2>/dev/null || true)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  tmp="$EPOCH.tmp.$$"
  printf 'epoch=%s owner_pid=%s outcome=%s updated_at=%s\n' \
    "$seq" "${BASHPID:-$$}" "$outcome" "$(date +%s)" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$EPOCH" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

write_epoch arming

# X mode cadence: source the generated config so an X instance polls at its
# 30s cadence (fm-bootstrap.sh x_mode_setup contract).
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

# --- foreground the real arm wrapper ------------------------------------------
# NO shell &: this hook process tree is the harness-owned lifecycle. The arm
# forks the watcher as its own tracked child exactly as it does for the
# model-driven background-task path, and propagates the wake reason on close.
OUT=$(mktemp "$STATE/.claude-autoarm-output.XXXXXX") || OUT=
if [ -n "$OUT" ]; then
  "$SCRIPT_DIR/fm-watch-arm.sh" >"$OUT" 2>&1
  RC=$?
else
  "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1
  RC=$?
fi

# --- classify and translate ---------------------------------------------------
# AFK may have appeared mid-cycle: the daemon owns triage now, so suppress the
# rewake even for an actionable close.
if [ -e "$STATE/.afk" ]; then
  write_epoch afk
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

ACTIONABLE=0
FAILED=0
if [ -n "$OUT" ]; then
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" 2>/dev/null && ACTIONABLE=1
  grep -q '^watcher: FAILED' "$OUT" 2>/dev/null && FAILED=1
fi
[ "$RC" -ne 0 ] && FAILED=1

if [ "$ACTIONABLE" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
  write_epoch clean
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

# The need may have vanished mid-cycle (fleet torn down, X opted out): nothing
# left to supervise, so close quietly instead of waking the model.
if ! need_supervision; then
  write_epoch clean
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

write_epoch rewake
if [ "$FAILED" -eq 1 ]; then
  {
    printf 'firstmate watcher cycle FAILED - supervision is down while this home still needs it.\n'
    [ -n "$OUT" ] && grep -E '^(watcher:|signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    printf 'Run bin/fm-wake-drain.sh first. Then repair supervision with bin/fm-watch-arm.sh as its own Claude Code background task (never shell &); it attaches when a healthy watcher already exists, so never reach for a restart to silence a repeated report. If the failure repeats, treat it as a blocker and report it instead of ending blind.\n'
  } >&2
else
  {
    printf 'firstmate watcher wake - one supervision event needs a handling turn now.\n'
    [ -n "$OUT" ] && grep -E '^(signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    printf 'Run bin/fm-wake-drain.sh first and handle the wake. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n'
  } >&2
fi
[ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
exit 2
