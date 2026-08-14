#!/usr/bin/env bash
# fm-fleet-work-index.sh - one cross-home index of every open work item.
#
# Routed work lives in the owning home's own backlog (AGENTS.md section 10), so
# no single backlog shows the fleet's real workload. This command reads this
# home's data/backlog.md plus the data/backlog.md of every home reachable from
# data/secondmates.md, and prints one list of open items: id, title, state,
# owning mate, and age.
#
# Discovery is TRANSITIVE, because a secondmate home can itself have spawned
# secondmates and their work is just as invisible from here. Each home found in
# a registry is asked for its own data/secondmates.md, and every home found that
# way is indexed exactly like any other. A home with no registry simply has no
# secondmates and is not a skip. A registry that EXISTS but cannot be read is a
# different condition: the homes it would have named cannot be enumerated at
# all, so that home's own record carries a subtree_reason saying so, rather than
# the home passing as childless. Each resolved physical path is visited at most
# once, so a registry cycle terminates on its own and the repeat visit is
# reported as already indexed rather than walked again.
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
# Homes are resolved from the registries, never from a hardcoded path list, so a
# home added or moved in a data/secondmates.md is picked up with no change here.
# This home's own group is labelled "main", or by its identity marker when the
# index is run from inside a seeded secondmate home.
#
# One unreadable home never fails the run. A home whose backlog is absent,
# unreadable, or unparseable is skipped, reported by name in a Skipped section
# (--json: skipped=true with a reason), and every other home is still indexed. A
# home whose registry is unreadable is still an indexed home, counted once as a
# home that was read; what could not be enumerated is its secondmates, so that
# fact is attached to the home itself rather than standing in for a home.
# Silence is never how a home leaves this index.
#
# A skip is not by itself a gap in the answer, and a consumer must not read it
# as one: most skips are ordinary. A seeded secondmate home has no
# data/backlog.md until work is filed in it, and a home reached twice through
# the registry graph is already counted under its first visit - both are
# skipped=true over items[] that are genuinely complete. Each home record
# therefore carries work_unknown, the one machine-readable answer to "may this
# home's absence from items[] be read as nothing open here?". It is true when a
# backlog exists but cannot be read or parsed, when the home cannot be resolved
# or found at all, and whenever subtree_reason is non-null, since an
# unenumerable registry hides a whole subtree of homes and their work. It is
# false for the two ordinary skips above. `reason` stays the operator-readable
# text and is unchanged; nothing downstream should match its wording.
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
# Worded so it cannot be read as the home's own backlog being unreadable: what
# failed is the enumeration of that home's secondmates, not its own work.
UNENUMERABLE_REASON="secondmate registry is unreadable, so this home's secondmates could not be enumerated"
TITLE_CAP=200
REASON_CAP=200
HUMAN_TITLE_CAP=96

usage() {
  cat <<'EOF'
usage: fm-fleet-work-index.sh [--json]

Prints every open backlog item across this home and every home reachable from
data/secondmates.md, grouped by owning mate and sorted by state then age.
Discovery is transitive: each home found is asked for its own registry too, so
a secondmate's own secondmates are indexed as well, each home visited once.
Read-only: no home's backlog is ever modified. A home with no readable backlog
is skipped by name, and a home whose own registry exists but cannot be read says
so against its own group; nothing is ever dropped silently.

  --json   emit the fm-fleet-work-index.v1 object instead of the human view
EOF
}

[ "$#" -le 1 ] || {
  usage >&2
  exit 2
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
registry_ids() { # <registry-path>
  [ -f "$1" ] && [ -r "$1" ] || return 0
  sed -n 's/^- \([A-Za-z0-9][A-Za-z0-9._-]*\) - .*/\1/p' "$1"
}

# Absent and unreadable are different answers about a home's secondmates, and
# collapsing them would let a whole subtree disappear with nothing said. Absent
# means the home has no secondmates, which is ordinary. Unreadable means its
# secondmates exist as far as anyone here knows but cannot be named at all.
registry_state() { # <registry-path> -> absent|readable|unreadable
  if [ ! -e "$1" ]; then
    printf 'absent\n'
  elif [ -f "$1" ] && [ -r "$1" ]; then
    printf 'readable\n'
  else
    printf 'unreadable\n'
  fi
}

# One registry's entries as "<id><tab><home>" rows, home empty when the entry
# records none. Only ever called for a registry that registry_state called
# readable, so an empty result here means the file genuinely names no homes.
registry_rows() { # <registry-path>
  local reg=$1 id home
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    home=$(secondmate_registry_field "$reg" "$id" home 2>/dev/null || true)
    printf '%s\t%s\n' "$id" "$home"
  done < <(registry_ids "$reg")
}

# One home's open items as a JSON object:
#   {mate, home, backlog, registry, skipped, reason, subtree_reason,
#    work_unknown, unstructured, items[]}
# A home that cannot be read yields skipped=true with a reason and no items,
# which is a normal result here, never an error. subtree_reason is about this
# home's SECONDMATES rather than its own work, so it rides on the home's own
# record: a home whose registry could not be enumerated was still indexed and
# must stay exactly one home. Every path a record carries is a path this run
# actually inspected; a path that does not exist stays null rather than being
# synthesized into something a reader could go looking for.
#
# work_unknown answers the one question a machine consumer has that `reason`
# cannot: may this home's absence from items[] be read as "nothing open here"?
# skipped alone cannot say, because most skips are ordinary - a seeded
# secondmate home has no data/backlog.md until work is filed in it
# (bin/fm-home-seed.sh writes none), and a home reached twice through the
# registry graph is already counted under its first visit. Both of those are
# skipped=true with items[] that are genuinely complete. It is `reason` that
# stays the operator-readable text; this is the predicate a consumer acts on,
# so nothing downstream has to match reason strings to tell the two apart.
home_index_json() { # <mate> <home-dir> [<skip-reason>] [<subtree-reason>] [<skip-work-unknown>]
  local mate=$1 home=$2 preskip=${3:-} subtree=${4:-} preskip_unknown=${5:-true}
  local backlog="" registry="" raw unknown
  if [ -n "$home" ]; then
    backlog="$home/data/backlog.md"
    [ -e "$home/data/secondmates.md" ] && registry="$home/data/secondmates.md"
  fi

  # A registry this run could not enumerate hides a whole subtree of homes and
  # every open item in it, so this home's own readable backlog cannot make the
  # answer complete.
  unknown=false
  [ -z "$subtree" ] || unknown=true

  if [ -n "$preskip" ]; then
    [ "$preskip_unknown" = false ] || unknown=true
    home_skip_json "$mate" "$home" "$backlog" "$preskip" "$registry" "$subtree" "$unknown"
    return 0
  fi
  # No backlog file is not a gap in the answer: a home with no backlog has no
  # open backlog rows, which is exactly what a consumer needs to know.
  if [ ! -e "$backlog" ]; then
    home_skip_json "$mate" "$home" "$backlog" "no backlog file" "$registry" "$subtree" "$unknown"
    return 0
  fi
  # A backlog that exists but cannot be read or parsed is a real gap: its rows
  # may name open work nobody here can see.
  if [ ! -f "$backlog" ] || [ ! -r "$backlog" ]; then
    home_skip_json "$mate" "$home" "$backlog" "backlog file is not readable" "$registry" "$subtree" true
    return 0
  fi
  if ! raw=$(backlog_json "$backlog" 2>/dev/null) || [ -z "$raw" ]; then
    home_skip_json "$mate" "$home" "$backlog" "backlog could not be parsed" "$registry" "$subtree" true
    return 0
  fi

  printf '%s' "$raw" | jq \
    --arg mate "$mate" \
    --arg home "$home" \
    --arg backlog "$backlog" \
    --arg registry "$registry" \
    --arg subtree "$subtree" \
    --argjson work_unknown "$unknown" \
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
       registry: (if $registry == "" then null else $registry end),
       skipped: false,
       reason: null,
       subtree_reason: (if $subtree == "" then null else $subtree end),
       work_unknown: $work_unknown,
       unstructured: $unstructured,
       items: $items}'
}

home_skip_json() { # <mate> <home-dir> <backlog-path-or-empty> <reason> [<registry-path-or-empty>] [<subtree-reason>] [<work-unknown>]
  jq -n \
    --arg mate "$1" \
    --arg home "$2" \
    --arg backlog "$3" \
    --arg reason "$4" \
    --arg registry "${5:-}" \
    --arg subtree "${6:-}" \
    --argjson work_unknown "${7:-true}" \
    '{mate:$mate,home:$home,
      backlog:(if $backlog == "" then null else $backlog end),
      registry:(if $registry == "" then null else $registry end),
      skipped:true,reason:$reason,
      subtree_reason:(if $subtree == "" then null else $subtree end),
      work_unknown:$work_unknown,
      unstructured:0,items:[]}'
}

# Walk every home reachable from this home's registry, breadth first, emitting
# one record per home. Each home that resolves to a path not yet visited is
# asked for its own registry, so a secondmate's secondmates are indexed too.
# The visited-path set is what terminates the walk: a cycle reaches an
# already-visited path, which is reported as already indexed and not descended.
collect_homes_json() {
  local id home reason reason_unknown seen=" " resolved frontier next state subtree
  state=$(registry_state "$REGISTRY")
  subtree=""
  [ "$state" != unreadable ] || subtree=$UNENUMERABLE_REASON
  home_index_json "$SELF_MATE" "$SELF_HOME" "" "$subtree"
  seen="$seen$SELF_HOME "
  frontier=""
  [ "$state" != readable ] || frontier=$(registry_rows "$REGISTRY")

  while [ -n "$frontier" ]; do
    next=""
    while IFS=$'\t' read -r id home; do
      [ -n "$id" ] || continue
      reason=""
      # A registered home this run could not reach at all keeps whatever open
      # work it holds invisible, so its skip is a genuine gap by default.
      reason_unknown=true
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
          # Reached twice through the registry graph. Its items are already in
          # this index under the first visit, so nothing is missing here.
          *" $home "*)
            reason="home already indexed under another registry id"
            reason_unknown=false
            ;;
          *) seen="$seen$home " ;;
        esac
      fi
      # Only a freshly resolved home is descended into: re-reading a registry
      # already walked is what would make a cycle loop forever.
      state=absent
      subtree=""
      if [ -z "$reason" ]; then
        state=$(registry_state "$home/data/secondmates.md")
        [ "$state" != unreadable ] || subtree=$UNENUMERABLE_REASON
      fi
      home_index_json "$id" "$home" "$reason" "$subtree" "$reason_unknown"
      [ "$state" != readable ] || next="$next$(registry_rows "$home/data/secondmates.md")"$'\n'
    done <<< "$frontier"
    frontier=$(printf '%s' "$next" | sed '/^$/d')
  done
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
       skipped: ($skipped | map({mate, home, backlog, registry, reason, subtree_reason, work_unknown})),
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
            # Free-form lines sitting under In flight/Queued are not open items
            # (decision 3), but they are work someone wrote down, so the count
            # is named here rather than leaving the section reading as empty.
            | (if .unstructured > 0
               then ", " + plural(.unstructured; "free-form row") + " not counted"
               else "" end) as $freeform
            # A home whose own secondmates could not be enumerated was still
            # indexed, so the gap is named against its group rather than
            # claiming the home itself went unread.
            | (if .subtree_reason == null then []
               else ["  ! \(.subtree_reason)"
                     + (if .registry == null then "" else " (\(.registry))" end)]
               end) as $subtree
            | ["## \($mate) - " + plural(([$index.items[] | select(.home == $h)] | length); "open item") + $freeform]
              + $subtree
              + [""]
              + ([ $index.items[] | select(.home == $h)
                   | "  \(state_label)  \(age | . + (" " * (5 - length)))  \(.id) - \(.title | trunc($title_cap))" ]
                 | if length == 0 then ["  (none)"] else . end)
              + [""] ]
          | add // [])
       + (if (.totals.homes_skipped) > 0
          then ["## Skipped homes (not indexed, nothing assumed about their work)", ""]
               + [ .skipped[]
                   # The path shown is whichever file the skip is about, and is
                   # omitted when the skip is about no file at all.
                   | (.backlog // .registry) as $path
                   | "  \(.mate) - \(.reason)"
                     + (if $path == null then "" else " (\($path))" end)
                     + (if .subtree_reason == null then ""
                        else "; \(.subtree_reason)"
                             + (if .registry == null then "" else " (\(.registry))" end)
                        end) ]
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
