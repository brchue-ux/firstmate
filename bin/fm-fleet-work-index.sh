#!/usr/bin/env bash
# fm-fleet-work-index.sh - one cross-home index of every open work item.
#
# Routed work lives in the owning home's own backlog (AGENTS.md section 10), so
# no single backlog shows the fleet's real workload. This command reads this
# home's data/backlog.md plus the data/backlog.md of every home registered in
# data/secondmates.md, and prints one list of open items: id, title, state,
# owning mate, and age.
#
# Usage:
#   fm-fleet-work-index.sh            grouped human view
#   fm-fleet-work-index.sh --json     machine-readable index (fm-fleet-work-index.v1)
#   fm-fleet-work-index.sh --help
#
# READ-ONLY, in both directions. It never mutates any home's backlog, never
# takes the session lock, never drains wakes, and never writes into a secondmate
# home: it opens other homes' files for reading and nothing else.
#
# Homes are resolved from the registry, never from a hardcoded path list, so a
# home added or moved in data/secondmates.md is picked up with no change here.
# This home's own group is labelled "main", or by its identity marker when the
# index is run from inside a seeded secondmate home.
#
# One unreadable home never fails the run. A home whose backlog is absent,
# unreadable, or unparseable is skipped, reported by name in a Skipped section
# (--json: skipped=true with a reason), and every other home is still indexed.
# Silence is never how a home leaves this index.
#
# Open means a structured backlog row under `## In flight` or `## Queued` whose
# checkbox is unticked; a ticked row in a current section is already finished and
# is left out. data/backlog.md's markdown shape has one parser owner,
# bin/fm-backlog-parse-lib.sh, shared with bin/fm-fleet-snapshot.sh.
#
# Age is days since the item was filed (its `since` date), not since it was
# dispatched, and is null/"-" for a row that records no date.
#
# Sorting is the same in both output modes: in-flight before queued, then oldest
# first, then by id. Homes are grouped with this home first, then by open count
# descending. --json also carries a flat items[] array, in that same order, so a
# consumer (such as an intake duplicate check) can look work up without
# regrouping or re-parsing any home.
#
# Requires jq.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# FM_HOME resolution, including the refusal on an ambiently inherited home,
# has one owner: bin/fm-home-anchor-lib.sh.
# shellcheck source=bin/fm-home-anchor-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-home-anchor-lib.sh"
fm_home_anchor_resolve "$FM_ROOT" || exit 1
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-backlog-parse-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backlog-parse-lib.sh"  # backlog_json: shared data/backlog.md parser
# shellcheck source=bin/fm-ff-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-ff-lib.sh"  # secondmate_registry_field: shared registry field parser

REGISTRY="$DATA/secondmates.md"
# Physical path, so a registry entry reaching this same home through a symlinked
# route is recognized as already indexed instead of being counted twice.
SELF_HOME=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || SELF_HOME=$FM_HOME
[ -n "$SELF_HOME" ] || SELF_HOME=$FM_HOME
# Label for this home's own group. A seeded secondmate home knows its own name
# from its identity marker (bin/fm-home-seed.sh), so running the index there
# groups its work under that name instead of mislabelling it "main".
SELF_MATE=main
if [ -s "$FM_HOME/$SUB_HOME_MARKER" ]; then
  SELF_MATE=$(tr -d '[:space:]' < "$FM_HOME/$SUB_HOME_MARKER" 2>/dev/null || true)
  [ -n "$SELF_MATE" ] || SELF_MATE=main
fi
TITLE_CAP=200
REASON_CAP=200
HUMAN_TITLE_CAP=96

usage() {
  cat <<'EOF'
usage: fm-fleet-work-index.sh [--json]

Prints every open backlog item across this home and every home registered in
data/secondmates.md, grouped by owning mate and sorted by state then age.
Read-only: no home's backlog is ever modified. A home with no readable backlog
is skipped by name, never dropped silently.

  --json   emit the fm-fleet-work-index.v1 object instead of the human view
EOF
}

case "${1:-}" in
  '') OUTPUT_MODE=human ;;
  --json) OUTPUT_MODE=json ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

command -v jq >/dev/null 2>&1 || {
  echo "fm-fleet-work-index: jq is required" >&2
  exit 1
}

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NOW_EPOCH=$(date -u +%s)

# Registry ids, in registry order. The line shape is "- <id> - <description>
# (home: ...; scope: ...; ...)"; only the leading id token is taken here, and
# secondmate_registry_field owns pulling fields back out of that same line.
registry_ids() {
  [ -f "$REGISTRY" ] || return 0
  sed -n 's/^- \([A-Za-z0-9][A-Za-z0-9._-]*\) - .*/\1/p' "$REGISTRY"
}

# One home's open items as a JSON object:
#   {mate, home, backlog, skipped, reason, unstructured, items[]}
# A home that cannot be read yields skipped=true with a reason and no items,
# which is a normal result here, never an error.
home_index_json() { # <mate> <home-dir> [<skip-reason>]
  local mate=$1 home=$2 preskip=${3:-} backlog raw
  backlog="$home/data/backlog.md"

  if [ -n "$preskip" ]; then
    home_skip_json "$mate" "$home" "$backlog" "$preskip"
    return 0
  fi
  if [ ! -e "$backlog" ]; then
    home_skip_json "$mate" "$home" "$backlog" "no backlog file"
    return 0
  fi
  if [ ! -f "$backlog" ] || [ ! -r "$backlog" ]; then
    home_skip_json "$mate" "$home" "$backlog" "backlog file is not readable"
    return 0
  fi
  if ! raw=$(backlog_json "$backlog" 2>/dev/null) || [ -z "$raw" ]; then
    home_skip_json "$mate" "$home" "$backlog" "backlog could not be parsed"
    return 0
  fi

  printf '%s' "$raw" | jq \
    --arg mate "$mate" \
    --arg home "$home" \
    --arg backlog "$backlog" \
    --argjson now "$NOW_EPOCH" \
    --argjson title_cap "$TITLE_CAP" \
    --argjson reason_cap "$REASON_CAP" '
    def trunc($n):
      if . == null then null
      else tostring | gsub("\\s+"; " ")
           | if length > $n then .[:$n] + "…" else . end
      end;
    # Days since the item was filed. An absent or unparseable date stays null
    # rather than becoming a misleading zero.
    def age_days($since):
      if $since == null or $since == "" then null
      else (try ($since | strptime("%Y-%m-%d") | mktime) catch null) as $t
           | if $t == null then null else (($now - $t) / 86400 | floor) end
      end;
    [ .records[]?
      | select(.structured == true)
      | select(.state == "in_flight" or .state == "queued")
      | select((.checked // false) | not)
      | {mate: $mate,
         home: $home,
         id: .id,
         title: (.title | trunc($title_cap)),
         state: .state,
         since: .since,
         age_days: age_days(.since),
         kind: .kind,
         priority: .priority,
         held: (.hold_reason != null and .hold_kind != null),
         hold_kind: .hold_kind,
         hold_reason: (.hold_reason | trunc($reason_cap)),
         blocked_by_ids: (.blocked_by_ids // []),
         unresolved_blocker_ids: (.unresolved_blocker_ids // [])} ] as $items
    | ([ .records[]?
         | select((.structured | not) and (.state == "in_flight" or .state == "queued")) ]
       | length) as $unstructured
    | {mate: $mate,
       home: $home,
       backlog: $backlog,
       skipped: false,
       reason: null,
       unstructured: $unstructured,
       items: $items}'
}

home_skip_json() { # <mate> <home-dir> <backlog-path> <reason>
  jq -n \
    --arg mate "$1" \
    --arg home "$2" \
    --arg backlog "$3" \
    --arg reason "$4" \
    '{mate:$mate,home:$home,backlog:$backlog,skipped:true,reason:$reason,
      unstructured:0,items:[]}'
}

collect_homes_json() {
  local id home reason seen=" " resolved
  home_index_json "$SELF_MATE" "$SELF_HOME"
  seen="$seen$SELF_HOME "

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    reason=""
    home=$(secondmate_registry_field "$REGISTRY" "$id" home 2>/dev/null || true)
    if [ -z "$home" ]; then
      reason="registry entry records no home"
    else
      case "$home" in
        /*) : ;;
        *) reason="registry home path is not absolute" ;;
      esac
    fi
    if [ -z "$reason" ]; then
      if resolved=$(cd "$home" 2>/dev/null && pwd -P); then
        home=$resolved
      else
        reason="home directory not found"
      fi
    fi
    if [ -z "$reason" ]; then
      case "$seen" in
        *" $home "*) reason="home already indexed under another registry id" ;;
        *) seen="$seen$home " ;;
      esac
    fi
    home_index_json "$id" "$home" "$reason"
  done < <(registry_ids)
}

# Assemble the whole index. Homes keep this home first, then most open work
# first; items sort in-flight before queued, then oldest first, then by id.
index_json() {
  collect_homes_json | jq -s \
    --arg schema fm-fleet-work-index.v1 \
    --arg generated "$NOW" \
    --arg self_home "$SELF_HOME" \
    --arg registry "$REGISTRY" '
    def state_rank: if .state == "in_flight" then 0 else 1 end;
    # Oldest first, so a null (undated) row sorts last instead of newest.
    def age_rank: (.age_days // -1) | -.;
    (map(select(.skipped | not))) as $read
    | (map(select(.skipped))) as $skipped
    | ($read
       | map(.items |= sort_by([state_rank, age_rank, .id]))
       | sort_by([(if .home == $self_home then 0 else 1 end),
                  -(.items | length),
                  .mate])) as $homes
    | ([$homes[].items[]] | sort_by([state_rank, age_rank, .id])) as $items
    | {schema: $schema,
       generated: $generated,
       home: $self_home,
       registry: $registry,
       totals: {homes: (($read | length) + ($skipped | length)),
                homes_read: ($read | length),
                homes_skipped: ($skipped | length),
                items: ($items | length),
                in_flight: ([$items[] | select(.state == "in_flight")] | length),
                queued: ([$items[] | select(.state == "queued")] | length)},
       homes: ($homes | map(del(.items)) + ($skipped | map(del(.items)))),
       skipped: ($skipped | map({mate, home, backlog, reason})),
       items: $items}'
}

render_human() { # <index-json>
  printf '%s' "$1" | jq -r \
    --argjson title_cap "$HUMAN_TITLE_CAP" '
    def trunc($n):
      tostring | gsub("\\s+"; " ")
      | if length > $n then .[:$n - 1] + "…" else . end;
    def age: if .age_days == null then "-" else "\(.age_days)d" end;
    def state_label: if .state == "in_flight" then "in-flight" else "queued   " end;
    def plural($n; $word): "\($n) \($word)" + (if $n == 1 then "" else "s" end);
    . as $index
    | (["Fleet work index - \(.generated)",
        (plural(.totals.items; "open item") + " across "
         + plural(.totals.homes_read; "home")
         + " (\(.totals.in_flight) in flight, \(.totals.queued) queued)"
         + (if .totals.homes_skipped > 0
            then "; \(.totals.homes_skipped) skipped" else "" end)),
        ""]
       # Grouped by home path, not by label: two homes could carry the same
       # name, and an item must appear under exactly one group.
       + ([ .homes[] | select(.skipped | not) | .home as $h | .mate as $mate
            | ["## \($mate) - " + plural(([$index.items[] | select(.home == $h)] | length); "open item"),
               ""]
              + ([ $index.items[] | select(.home == $h)
                   | "  \(state_label)  \(age | . + (" " * (5 - length)))  \(.id) - \(.title | trunc($title_cap))" ]
                 | if length == 0 then ["  (none)"] else . end)
              + [""] ]
          | add // [])
       + (if (.totals.homes_skipped) > 0
          then ["## Skipped homes (not indexed, nothing assumed about their work)", ""]
               + [ .skipped[] | "  \(.mate) - \(.reason) (\(.backlog))" ]
               + [""]
          else [] end)
      )
    | .[]'
}

INDEX=$(index_json) || {
  echo "fm-fleet-work-index: index build failed" >&2
  exit 1
}

if [ "$OUTPUT_MODE" = json ]; then
  printf '%s\n' "$INDEX"
else
  render_human "$INDEX"
fi
