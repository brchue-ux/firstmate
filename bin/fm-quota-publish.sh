#!/usr/bin/env bash
# Publish this Firstmate home's own account-level quota into herdr: the
# 5-hour (session) and 7-day (weekly) windows' current percentage and reset
# time, so the fleet sidebar can render a native quota readout instead of
# relying on an external statusline script. See
# data/decisions/2026-08-07-context-window-sparkline-scope.md for the design
# this follows; nothing here re-derives that reasoning.
#
# `quota-axi --json` is the fleet's own existing source for every provider's
# window percentages and resetsAt timestamps. This reads one caller-named
# provider's two account-level windows - selected by `kind` ("session" and
# "weekly"), not by the `id` field, because the id string is not uniform
# across providers - and publishes them as two herdr metadata tokens,
# mirroring bin/fm-quality-event.sh's target-resolution and publish pattern:
#   quota_5h=<percentUsed>@<resetsAt ISO8601>
#   quota_7d=<percentUsed>@<resetsAt ISO8601>
# Publishing the raw resetsAt timestamp rather than a pre-computed duration
# mirrors fm-quality-event.sh's streak=<value>@<ts> shape: the consumer
# (herdr-side rendering, a separate task) computes the live
# time-remaining-to-reset at render time, so the number never goes stale
# between publishes. A window with no resetsAt in the source is published as
# just <percentUsed>, with no trailing "@".
#
# Unlike the per-task/per-mate sibling scripts (fm-herdr-outcome-publish.sh,
# fm-quality-event.sh), quota is a whole-HOME fact, not tied to one task or
# mate: the herdr target is THIS FM_HOME's own durable workspace
# (fm_backend_herdr_workspace_label - "firstmate" for a primary,
# "2ndmate-<id>" for a secondmate), resolved the same home-level way
# bin/fm-herdr-session-cleanup.sh resolves its own session and workspace,
# never a task's state/<id>.meta.
#
# Reading and parsing quota-axi's own output is the core computation: a
# missing tool, a failed call, an unknown provider, or a provider missing
# either window is a caller-visible error (matching fm-quality-event.sh's
# ledger-write requirements). Only the herdr publish step below that is a
# decoration, never a blocker: a missing herdr session/workspace, the herdr
# or jq tools missing, or the CLI call itself failing is a silent no-op that
# exits 0.
#
# Usage: fm-quota-publish.sh <provider>
#   <provider>  the quota-axi provider id whose session/weekly windows to
#               publish, e.g. claude, codex, grok, kimi
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# FM_HOME resolution, including the refusal on an ambiently inherited home,
# has one owner: bin/fm-home-anchor-lib.sh.
# shellcheck source=bin/fm-home-anchor-lib.sh
. "$SCRIPT_DIR/fm-home-anchor-lib.sh"

fm_quota_publish_usage() {
  echo "usage: fm-quota-publish.sh <provider>" >&2
}

if [ "$#" -ne 1 ]; then
  fm_quota_publish_usage
  exit 2
fi
PROVIDER=$1
[ -n "$PROVIDER" ] || { fm_quota_publish_usage; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "fm-quota-publish.sh: jq is required" >&2; exit 1; }
command -v quota-axi >/dev/null 2>&1 || {
  echo "fm-quota-publish.sh: quota-axi is required" >&2
  exit 1
}

QUOTA_JSON=$(quota-axi --json 2>/dev/null) || {
  echo "fm-quota-publish.sh: quota-axi --json failed" >&2
  exit 1
}

WINDOWS=$(printf '%s' "$QUOTA_JSON" | jq -er --arg p "$PROVIDER" \
  '[.providers[]? | select(.provider == $p)][0] | .windows // empty') || {
  echo "fm-quota-publish.sh: no provider '$PROVIDER' in quota-axi output" >&2
  exit 1
}

fm_quota_publish_read_window() {  # <windows-json> <kind>
  printf '%s' "$1" | jq -er --arg kind "$2" \
    '[.[] | select(.kind == $kind)][0] | select(.percentUsed != null)
     | [(.percentUsed | tostring), (.resetsAt // "")] | @tsv' \
    2>/dev/null
}

FIVE_HOUR=$(fm_quota_publish_read_window "$WINDOWS" session) || {
  echo "fm-quota-publish.sh: no readable session (5-hour) window for provider '$PROVIDER'" >&2
  exit 1
}
SEVEN_DAY=$(fm_quota_publish_read_window "$WINDOWS" weekly) || {
  echo "fm-quota-publish.sh: no readable weekly (7-day) window for provider '$PROVIDER'" >&2
  exit 1
}

fm_quota_publish_token_value() {  # <pct-tab-resets-tsv-line>
  local pct=${1%%$'\t'*} resets=${1#*$'\t'}
  if [ -n "$resets" ]; then
    printf '%s@%s' "$pct" "$resets"
  else
    printf '%s' "$pct"
  fi
}

TOKEN_5H=$(fm_quota_publish_token_value "$FIVE_HOUR")
TOKEN_7D=$(fm_quota_publish_token_value "$SEVEN_DAY")

# Everything below is herdr target resolution and the publish call: any
# failure here is a decoration dropped, never a caller-visible error,
# mirroring fm-herdr-outcome-publish.sh's and fm-quality-event.sh's
# established pattern for the same reason.
fm_home_anchor_resolve "$FM_ROOT" >/dev/null 2>&1 || exit 0

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source herdr >/dev/null 2>&1 || exit 0
fm_backend_herdr_tool_check >/dev/null 2>&1 || exit 0

SESSION=$(fm_backend_herdr_session)
WORKSPACE=$(fm_backend_herdr_workspace_find "$SESSION") || exit 0
[ -n "$WORKSPACE" ] || exit 0

# The workspace_id positional must precede the options for this herdr CLI
# version (verified live against 0.8.0): trailing it after --token errors
# "unknown option: <workspace_id>" rather than parsing it as the positional.
fm_backend_herdr_cli "$SESSION" workspace report-metadata "$WORKSPACE" \
  --source firstmate \
  --token "quota_5h=$TOKEN_5H" \
  --token "quota_7d=$TOKEN_7D" \
  >/dev/null 2>&1 || true

exit 0
