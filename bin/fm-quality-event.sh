#!/usr/bin/env bash
# Record one quality-streak event for a mate, and publish the decayed readout
# to herdr. See data/herdr-severity-and-weighting/report.md sections B (the
# severity guard), D (the weighting table), and F (storage shape) for the
# design this follows; nothing here re-derives that reasoning.
#
# 1. Appends one JSONL line to data/quality-ledger/<mate>.jsonl (created if
#    absent). Each append is a single `printf ... >>` write, which is atomic
#    under PIPE_BUF, so concurrent mates writing their own files cannot
#    corrupt each other (report.md section F).
# 2. Recomputes the mate's decayed running total from every line in its
#    ledger: score * 2^(-(now-ts)/86400/hl), summed, clamped to >= -20
#    (report.md section D "Decay, bounds, and the readout").
# 3. Applies the severity guard (report.md section B): a stated severity that
#    contradicts a derived bound is corrected, never trusted as given.
#      - catch_before_land: only evidence is a red check on an unlanded
#        branch, so a stated S1 is capped at S2.
#      - merged_broken, silent_code_loss: the defect reached a landed commit,
#        so a stated S3/S4 is floored at S2.
#      - unstated ("-"): defaults to S3, mirroring Google's P2 default.
#        Never resolves to S1.
# 4. Publishes exactly three metadata tokens on the mate's own herdr Space,
#    mirroring fm-herdr-outcome-publish.sh's target-resolution pattern: read
#    backend/herdr_session/herdr_workspace_id from the mate's own
#    state/<mate>.meta (a secondmate is spawned like any task, so it carries
#    the same meta fields). This step is a decoration, never a blocker: any
#    unresolvable target is a silent no-op, and the herdr CLI call itself
#    never fails the script.
#      streak    = <decayed total>@<unix ts of this publish>
#      streak_hl = <win half-life>/<loss half-life> days, fixed at 5/10 - the
#                  dominant win/loss half-lives in section D's table. This is
#                  herdr's read-time decay approximation, deliberately
#                  decoupled from the ledger's own exact per-event half-life
#                  accounting (section F "Decay is computed at read time").
#      sev       = the guarded severity of this call's event when the event
#                  carries a severity concept, else "-". No open/closed
#                  defect lifecycle is tracked yet (section B "recurrence...
#                  needs a defect ledger that does not exist" - same gap),
#                  so "currently open" here means "most recently reported".
#
# Usage: fm-quality-event.sh <mate> <event> <size> <severity> <note>
#   <mate>      secondmate id; must match the same path-safe id rules as a
#               task id (fm_task_id_path_safe)
#   <event>     one of: catch_before_land attribution_corrected pr_merged
#               live_verification task_completed honest_limitation
#               merged_broken reported_done_false silent_code_loss
#               rework_after_ci_fail environmental
#   <size>      one of: XS S M L -   ("-" for an event with no size concept)
#   <severity>  one of: S1 S2 S3 S4 N/A -   ("-" for unstated)
#   <note>      short free-text note, stored in the ledger only, never
#               published to herdr (report.md section F "What must never be
#               published")
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# FM_HOME resolution: see bin/fm-home-anchor-lib.sh:1-22 ("Why this exists").
# shellcheck source=bin/fm-home-anchor-lib.sh
. "$SCRIPT_DIR/fm-home-anchor-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

fm_quality_event_usage() {
  echo "usage: fm-quality-event.sh <mate> <event> <size> <severity> <note>" >&2
}

if [ "$#" -ne 5 ]; then
  fm_quality_event_usage
  exit 2
fi
MATE=$1
EVENT=$2
SIZE=$3
SEVERITY=$4
NOTE=$5

fm_task_id_path_safe "$MATE" || {
  echo "fm-quality-event.sh: not a valid mate id: $MATE" >&2
  fm_quality_event_usage
  exit 2
}

case "$SIZE" in
  XS|S|M|L|-) ;;
  *)
    echo "fm-quality-event.sh: invalid size: $SIZE (want XS, S, M, L, or -)" >&2
    fm_quality_event_usage
    exit 2
    ;;
esac
case "$SEVERITY" in
  S1|S2|S3|S4|N/A|-) ;;
  *)
    echo "fm-quality-event.sh: invalid severity: $SEVERITY (want S1, S2, S3, S4, N/A, or -)" >&2
    fm_quality_event_usage
    exit 2
    ;;
esac

# Event table: sign, base, whether size multiplies it, whether severity
# multiplies it, decay half-life in days. report.md section D.
SIGN=0; BASE=0; USES_SIZE=0; USES_SEV=0; HL=0
case "$EVENT" in
  catch_before_land)      SIGN=1;  BASE=8;   USES_SEV=1; HL=7 ;;
  attribution_corrected)  SIGN=1;  BASE=5;   USES_SEV=1; HL=7 ;;
  pr_merged)              SIGN=1;  BASE=4;   USES_SIZE=1; HL=5 ;;
  live_verification)      SIGN=1;  BASE=3;   USES_SIZE=1; HL=5 ;;
  task_completed)         SIGN=1;  BASE=2;   USES_SIZE=1; HL=5 ;;
  honest_limitation)      SIGN=1;  BASE=2;   HL=5 ;;
  merged_broken)          SIGN=-1; BASE=9;   USES_SEV=1; HL=10 ;;
  reported_done_false)    SIGN=-1; BASE=8;   HL=10 ;;
  silent_code_loss)       SIGN=-1; BASE=8;   USES_SEV=1; HL=10 ;;
  rework_after_ci_fail)   SIGN=-1; BASE=1.5; USES_SIZE=1; HL=3 ;;
  environmental)          SIGN=0;  BASE=0;   HL=0 ;;
  *)
    echo "fm-quality-event.sh: unknown event: $EVENT" >&2
    fm_quality_event_usage
    exit 2
    ;;
esac

if [ "$USES_SIZE" -eq 1 ] && [ "$SIZE" = - ]; then
  echo "fm-quality-event.sh: event $EVENT is size-scored; size - (no size concept) is not valid (want XS, S, M, or L)" >&2
  fm_quality_event_usage
  exit 2
fi
if [ "$USES_SEV" -eq 1 ] && [ "$SEVERITY" = N/A ]; then
  echo "fm-quality-event.sh: event $EVENT is a defect event; severity N/A (not a defect) is not valid (want S1, S2, S3, S4, or -)" >&2
  fm_quality_event_usage
  exit 2
fi

fm_quality_size_mult() {  # <XS|S|M|L|->
  case "$1" in
    XS) echo 0.25 ;;
    S) echo 0.50 ;;
    M) echo 1.00 ;;
    L) echo 1.75 ;;
    *) echo 1 ;;
  esac
}

fm_quality_sev_mult() {  # <S1|S2|S3|S4|N/A>
  case "$1" in
    S1) echo 3.0 ;;
    S2) echo 2.0 ;;
    S3) echo 1.0 ;;
    S4) echo 0.5 ;;
    *) echo 1.0 ;;
  esac
}

# The severity guard (report.md section B). Only applied where severity
# actually scores the event; other events leave $SEVERITY untouched.
GUARDED_SEVERITY=$SEVERITY
if [ "$USES_SEV" -eq 1 ]; then
  case "$GUARDED_SEVERITY" in
    -|'') GUARDED_SEVERITY=S3 ;;
  esac
  case "$EVENT" in
    catch_before_land)
      [ "$GUARDED_SEVERITY" != S1 ] || GUARDED_SEVERITY=S2
      ;;
    merged_broken|silent_code_loss)
      case "$GUARDED_SEVERITY" in S3|S4) GUARDED_SEVERITY=S2 ;; esac
      ;;
  esac
fi

SIZE_MULT=$([ "$USES_SIZE" -eq 1 ] && fm_quality_size_mult "$SIZE" || echo 1)
SEV_MULT=$([ "$USES_SEV" -eq 1 ] && fm_quality_sev_mult "$GUARDED_SEVERITY" || echo 1)

command -v jq >/dev/null 2>&1 || { echo "fm-quality-event.sh: jq is required" >&2; exit 1; }
command -v awk >/dev/null 2>&1 || { echo "fm-quality-event.sh: awk is required" >&2; exit 1; }

fm_home_anchor_resolve "$FM_ROOT" || exit 1
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LEDGER_DIR="$DATA/quality-ledger"
LEDGER="$LEDGER_DIR/$MATE.jsonl"
mkdir -p "$LEDGER_DIR" || exit 1

NOW=$(date +%s)
EVENT_SCORE=$(awk -v b="$BASE" -v sz="$SIZE_MULT" -v sv="$SEV_MULT" -v sg="$SIGN" \
  'BEGIN { printf "%.4f", b * sz * sv * sg }')

LINE=$(jq -nc \
  --argjson ts "$NOW" \
  --arg mate "$MATE" \
  --arg event "$EVENT" \
  --arg size "$SIZE" \
  --arg severity "$GUARDED_SEVERITY" \
  --argjson score "$EVENT_SCORE" \
  --argjson hl "$HL" \
  --arg note "$NOTE" \
  '{ts:$ts, mate:$mate, event:$event, size:$size, severity:$severity, score:$score, hl:$hl, note:$note}') || exit 1
printf '%s\n' "$LINE" >> "$LEDGER" || exit 1

# Recompute the decayed running total from the whole ledger (report.md
# section D). Clamped to >= -20 so one bad night cannot erase a good month.
DECAYED=$(jq -r '[.ts, .score, .hl] | @tsv' "$LEDGER" 2>/dev/null | awk -F'\t' -v now="$NOW" '
  {
    hl = $3
    if (hl <= 0) { total += $2; next }
    delta_days = (now - $1) / 86400.0
    total += $2 * (2 ^ (-(delta_days / hl)))
  }
  END {
    if (total < -20) total = -20
    printf "%.2f", total
  }
')

# The published sev token reflects this call's own guarded severity when the
# event carries a severity concept, "-" otherwise (report.md section F).
SEV_TOKEN=-
[ "$USES_SEV" -ne 1 ] || SEV_TOKEN=$GUARDED_SEVERITY

# Everything below is herdr target resolution and the publish call: any
# failure here is a decoration dropped, never a caller-visible error, mirroring
# fm-herdr-outcome-publish.sh's established pattern for the same reason.
META="$STATE/$MATE.meta"
[ -f "$META" ] && [ ! -L "$META" ] || exit 0

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

[ "$(grep -c '^backend=' "$META" 2>/dev/null || true)" = 1 ] || exit 0
BACKEND=$(fm_backend_meta_exact_value "$META" backend) || exit 0
[ "$BACKEND" = herdr ] || exit 0

SESSION=$(fm_backend_meta_exact_value "$META" herdr_session) || exit 0
WORKSPACE=$(fm_backend_meta_exact_value "$META" herdr_workspace_id) || exit 0

fm_backend_source herdr >/dev/null 2>&1 || exit 0
fm_backend_herdr_tool_check >/dev/null 2>&1 || exit 0

WIN_HL=5
LOSS_HL=10
# The workspace_id positional must precede the options for this herdr CLI
# version (verified live against 0.8.0): trailing it after --token errors
# "unknown option: <workspace_id>" rather than parsing it as the positional.
fm_backend_herdr_cli "$SESSION" workspace report-metadata "$WORKSPACE" \
  --source firstmate \
  --token "streak=$DECAYED@$NOW" \
  --token "streak_hl=$WIN_HL/$LOSS_HL" \
  --token "sev=$SEV_TOKEN" \
  >/dev/null 2>&1 || true

exit 0
