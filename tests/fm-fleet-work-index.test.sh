#!/usr/bin/env bash
# Behavior tests for the read-only cross-home open-work index.
#
# Every assertion runs the real script against fixture homes and reads only its
# output and the fixtures' bytes on disk. Nothing here inspects the script's
# source: the contracts under test are what it prints, what it counts, what it
# refuses to drop silently, and what it leaves untouched.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INDEX="$ROOT/bin/fm-fleet-work-index.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-work-index)

command -v jq >/dev/null 2>&1 || {
  echo "skip: jq not found"
  exit 0
}

# --- fixtures ---------------------------------------------------------------

new_home() { # <name> -> echoes home dir
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data"
  printf '%s' "$home"
}

# Register a secondmate home. The description deliberately carries its own
# parentheses, matching real registry entries whose scope prose is full of them.
register() { # <main-home> <id> <home-dir> [<description>]
  local main=$1 id=$2 home=$3
  local desc=${4:-"Own all work (Apache-2.0) on the thing"}
  printf -- '- %s - %s (home: %s; scope: %s work; projects: %s; added 2026-07-09)\n' \
    "$id" "$desc" "$home" "$id" "$id" >> "$main/data/secondmates.md"
}

run_index() { # <home> [args...]
  local home=$1
  shift
  FM_HOME="$home" "$INDEX" "$@"
}

# Sum of every backlog byte in the fixture tree, used to prove read-only.
tree_digest() {
  find "$TMP_ROOT" -name backlog.md -type f -exec cksum {} + 2>/dev/null | sort
}

# --- tests ------------------------------------------------------------------

test_indexes_main_home_and_every_registered_mate() {
  local main sub_a sub_b out json
  main=$(new_home main-basic)
  sub_a=$(new_home mate-alpha)
  sub_b=$(new_home mate-beta)

  cat > "$main/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] main-flight - main home item under way (repo: firstmate) (kind: ship) (since 2026-07-01)
## Queued
- [ ] main-queued - main home queued item (repo: firstmate) (kind: ship) (since 2026-07-05)
- [x] main-superseded - finished but parked in Queued (repo: firstmate) (since 2026-07-02)
## Done
- [x] main-done - already landed (repo: firstmate) (merged 2026-07-06)
EOF

  cat > "$sub_a/data/backlog.md" <<'EOF'
# Backlog

## In flight
## Queued
- [ ] alpha-one - alpha queued one (repo: alpha) (since 2026-07-03)
- [ ] alpha-two - alpha queued two (repo: alpha) (since 2026-07-04)
## Done
EOF

  cat > "$sub_b/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] beta-flight - beta item under way (repo: beta) (since 2026-07-07)
## Queued
## Done
EOF

  register "$main" alpha "$sub_a"
  register "$main" beta "$sub_b"

  out=$(run_index "$main") || fail "index run failed on healthy homes"
  assert_contains "$out" "main-flight" "main home in-flight item missing from the index"
  assert_contains "$out" "alpha-one" "registered mate's queued item missing from the index"
  assert_contains "$out" "beta-flight" "second registered mate's item missing from the index"
  assert_not_contains "$out" "main-done" "a Done item leaked into the open-work index"
  assert_not_contains "$out" "main-superseded" \
    "a ticked row inside a current section was counted as open work"

  json=$(run_index "$main" --json) || fail "--json run failed on healthy homes"
  # 5 open rows: two in flight, three queued; the ticked and Done rows are out.
  [ "$(printf '%s' "$json" | jq -r '.totals.items')" = 5 ] \
    || fail "open item total is wrong: $(printf '%s' "$json" | jq -c '.totals')"
  [ "$(printf '%s' "$json" | jq -r '.totals.in_flight')" = 2 ] \
    || fail "in-flight total is wrong: $(printf '%s' "$json" | jq -c '.totals')"
  [ "$(printf '%s' "$json" | jq '[.items[] | select(.id == "main-superseded")] | length')" = 0 ] \
    || fail "a ticked row inside a current section reached the item list"
  [ "$(printf '%s' "$json" | jq -r '.totals.homes_read')" = 3 ] \
    || fail "expected all three homes to be read"
  [ "$(printf '%s' "$json" | jq -r '.totals.homes_skipped')" = 0 ] \
    || fail "no home should have been skipped here"
  [ "$(printf '%s' "$json" | jq -r '.items[] | select(.id == "alpha-one") | .mate')" = alpha ] \
    || fail "item was not attributed to its owning mate"
  [ "$(printf '%s' "$json" | jq -r '.items[] | select(.id == "main-flight") | .state')" = in_flight ] \
    || fail "In flight section did not become the in_flight state"

  pass "indexes this home plus every registered mate, open items only"
}

test_missing_backlog_skips_that_home_only() {
  local main sub_ok sub_missing out json
  main=$(new_home main-missing)
  sub_ok=$(new_home mate-present)
  sub_missing=$(new_home mate-absent) # exists, but never gets a backlog

  cat > "$main/data/backlog.md" <<'EOF'
## In flight
## Queued
- [ ] main-item - main still counts (repo: firstmate) (since 2026-07-01)
## Done
EOF
  cat > "$sub_ok/data/backlog.md" <<'EOF'
## In flight
## Queued
- [ ] present-item - readable mate still counts (repo: p) (since 2026-07-02)
## Done
EOF

  register "$main" present "$sub_ok"
  register "$main" absent "$sub_missing"

  out=$(run_index "$main") || fail "a home with no backlog aborted the whole run"
  assert_contains "$out" "main-item" "main home dropped out when another home was unreadable"
  assert_contains "$out" "present-item" "readable mate dropped out when another home was unreadable"
  assert_contains "$out" "absent" "the skipped home was not named in the output"

  json=$(run_index "$main" --json) || fail "--json aborted on a home with no backlog"
  [ "$(printf '%s' "$json" | jq -r '.skipped[] | select(.mate == "absent") | .reason')" = "no backlog file" ] \
    || fail "missing backlog was not reported with a reason"
  [ "$(printf '%s' "$json" | jq -r '.totals.homes_skipped')" = 1 ] \
    || fail "skipped-home count is wrong"
  [ "$(printf '%s' "$json" | jq -r '.totals.items')" = 2 ] \
    || fail "items from the readable homes were lost"
  [ "$(printf '%s' "$json" | jq '[.items[] | select(.mate == "absent")] | length')" = 0 ] \
    || fail "the skipped home somehow contributed items"

  pass "a home with no backlog is skipped by name without failing the run"
}

test_unreadable_backlog_skips_that_home_only() {
  local main sub_bad out json
  if [ "$(id -u)" -eq 0 ]; then
    echo "skip: running as root, file permissions do not deny reads"
    return 0
  fi
  main=$(new_home main-unreadable)
  sub_bad=$(new_home mate-chmod)

  cat > "$main/data/backlog.md" <<'EOF'
## In flight
## Queued
- [ ] survivor - unaffected by the unreadable home (repo: firstmate) (since 2026-07-01)
## Done
EOF
  cat > "$sub_bad/data/backlog.md" <<'EOF'
## In flight
## Queued
- [ ] hidden-item - cannot be read (repo: x) (since 2026-07-02)
## Done
EOF
  chmod 000 "$sub_bad/data/backlog.md"

  register "$main" chmodded "$sub_bad"

  out=$(run_index "$main") || fail "an unreadable backlog aborted the whole run"
  assert_contains "$out" "survivor" "readable work vanished because another backlog was unreadable"
  assert_contains "$out" "chmodded" "the unreadable home was not named in the output"
  assert_not_contains "$out" "hidden-item" "content of an unreadable backlog appeared anyway"

  json=$(run_index "$main" --json) || fail "--json aborted on an unreadable backlog"
  [ "$(printf '%s' "$json" | jq -r '.skipped[] | select(.mate == "chmodded") | .reason')" \
    = "backlog file is not readable" ] \
    || fail "unreadable backlog was not reported with a reason"

  chmod 644 "$sub_bad/data/backlog.md"
  pass "an unreadable backlog is skipped by name without failing the run"
}

test_registry_entry_without_a_home_is_skipped() {
  local main out json
  main=$(new_home main-nohome)
  cat > "$main/data/backlog.md" <<'EOF'
## In flight
## Queued
- [ ] kept - still indexed (repo: firstmate) (since 2026-07-01)
## Done
EOF
  printf -- '- orphan - a mate with no recorded home\n' >> "$main/data/secondmates.md"
  register "$main" ghost "$TMP_ROOT/never-created"

  out=$(run_index "$main") || fail "a broken registry entry aborted the run"
  assert_contains "$out" "kept" "healthy work dropped out over a broken registry entry"
  assert_contains "$out" "orphan" "registry entry with no home was not named as skipped"
  assert_contains "$out" "ghost" "registry entry naming a missing directory was not named as skipped"

  json=$(run_index "$main" --json) || fail "--json aborted on a broken registry entry"
  [ "$(printf '%s' "$json" | jq -r '.skipped[] | select(.mate == "orphan") | .reason')" \
    = "registry entry records no home" ] \
    || fail "registry entry with no home lacked its reason"
  [ "$(printf '%s' "$json" | jq -r '.skipped[] | select(.mate == "ghost") | .reason')" \
    = "home directory not found" ] \
    || fail "registry entry naming a missing directory lacked its reason"

  pass "a broken registry entry is skipped by name without failing the run"
}

test_sorted_by_state_then_age() {
  local main sub json ids
  main=$(new_home main-sort)
  sub=$(new_home mate-sort)

  cat > "$main/data/backlog.md" <<'EOF'
## In flight
- [ ] flight-new - newer in-flight item (repo: firstmate) (since 2026-07-10)
- [ ] flight-old - older in-flight item (repo: firstmate) (since 2026-07-01)
## Queued
- [ ] queued-new - newer queued item (repo: firstmate) (since 2026-07-09)
- [ ] queued-undated - queued item with no date (repo: firstmate)
- [ ] queued-old - older queued item (repo: firstmate) (since 2026-07-02)
## Done
EOF
  cat > "$sub/data/backlog.md" <<'EOF'
## In flight
## Queued
## Done
EOF
  register "$main" quiet "$sub"

  json=$(run_index "$main" --json) || fail "--json run failed on the sort fixture"
  ids=$(printf '%s' "$json" | jq -r '.items[].id' | paste -sd, -)
  [ "$ids" = "flight-old,flight-new,queued-old,queued-new,queued-undated" ] \
    || fail "items were not sorted in-flight first then oldest first (got: $ids)"

  # Ages are days since the recorded date, so the older item must read older.
  local old_age new_age
  old_age=$(printf '%s' "$json" | jq -r '.items[] | select(.id == "flight-old") | .age_days')
  new_age=$(printf '%s' "$json" | jq -r '.items[] | select(.id == "flight-new") | .age_days')
  [ "$old_age" -gt "$new_age" ] || fail "age did not increase with an older filing date"
  [ "$(printf '%s' "$json" | jq -r '.items[] | select(.id == "queued-undated") | .age_days')" = null ] \
    || fail "an undated item invented an age"

  pass "items sort by state then age, and an undated item sorts last without an age"
}

test_grouped_by_mate_with_this_home_first() {
  local main sub_big sub_small out json order groups
  main=$(new_home main-group)
  sub_big=$(new_home mate-big)
  sub_small=$(new_home mate-small)

  cat > "$main/data/backlog.md" <<'EOF'
## In flight
## Queued
- [ ] main-only - the only main item (repo: firstmate) (since 2026-07-01)
## Done
EOF
  cat > "$sub_big/data/backlog.md" <<'EOF'
## In flight
## Queued
- [ ] big-one - one (repo: b) (since 2026-07-01)
- [ ] big-two - two (repo: b) (since 2026-07-02)
- [ ] big-three - three (repo: b) (since 2026-07-03)
## Done
EOF
  cat > "$sub_small/data/backlog.md" <<'EOF'
## In flight
## Queued
- [ ] small-one - one (repo: s) (since 2026-07-01)
## Done
EOF
  register "$main" bigmate "$sub_big"
  register "$main" smallmate "$sub_small"

  json=$(run_index "$main" --json) || fail "--json run failed on the grouping fixture"
  order=$(printf '%s' "$json" | jq -r '.homes[] | select(.skipped | not) | .mate' | paste -sd, -)
  [ "$order" = "main,bigmate,smallmate" ] \
    || fail "homes were not ordered this-home-first then busiest first (got: $order)"

  out=$(run_index "$main") || fail "human view failed on the grouping fixture"
  groups=$(printf '%s' "$out" | sed -n 's/^## \([a-z]*\) - .*/\1/p' | paste -sd, -)
  [ "$groups" = "main,bigmate,smallmate" ] \
    || fail "human view groups were not in the same order (got: $groups)"
  # Each mate's items must sit under that mate's own heading.
  printf '%s' "$out" | awk '/^## bigmate /{f=1;next} /^## /{f=0} f' | grep -q 'big-two' \
    || fail "an item was not printed under its owning mate's group"

  pass "output is grouped by mate with this home first, then the busiest"
}

test_never_writes_to_any_home() {
  local main sub before after
  main=$(new_home main-readonly)
  sub=$(new_home mate-readonly)
  cat > "$main/data/backlog.md" <<'EOF'
## In flight
## Queued
- [ ] main-ro - main item (repo: firstmate) (since 2026-07-01)
## Done
EOF
  cat > "$sub/data/backlog.md" <<'EOF'
## In flight
## Queued
- [ ] sub-ro - mate item (repo: s) (since 2026-07-01)
## Done
EOF
  register "$main" romate "$sub"

  before=$(tree_digest)
  run_index "$main" >/dev/null || fail "read-only fixture run failed"
  run_index "$main" --json >/dev/null || fail "read-only --json fixture run failed"
  after=$(tree_digest)

  [ "$before" = "$after" ] || fail "a backlog file changed during an index run"
  assert_absent "$sub/state" "the index created state under a secondmate home"
  assert_absent "$main/state" "the index created state under this home"

  pass "an index run leaves every home's backlog byte-identical"
}

test_no_registered_mates_still_indexes_this_home() {
  local main out
  main=$(new_home main-alone)
  cat > "$main/data/backlog.md" <<'EOF'
## In flight
## Queued
- [ ] lonely - the only item in the fleet (repo: firstmate) (since 2026-07-01)
## Done
EOF

  out=$(run_index "$main") || fail "run failed with no registry present"
  assert_contains "$out" "lonely" "this home's work vanished when no mates were registered"

  pass "an absent registry still indexes this home"
}

test_seeded_home_labels_its_own_group_by_name() {
  local home json
  home=$(new_home mate-selfnamed)
  printf 'homeauto\n' > "$home/.fm-secondmate-home"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
## Queued
- [ ] own-item - work owned by this seeded home (repo: h) (since 2026-07-01)
## Done
EOF

  json=$(run_index "$home" --json) || fail "run failed inside a seeded secondmate home"
  [ "$(printf '%s' "$json" | jq -r '.items[] | select(.id == "own-item") | .mate')" = homeauto ] \
    || fail "a seeded home's own work was not attributed to that home's name"

  pass "a seeded secondmate home labels its own group by its recorded name"
}

test_help_and_bad_flag() {
  local main out rc=0
  main=$(new_home main-usage)
  : > "$main/data/backlog.md"

  out=$(run_index "$main" --help) || fail "--help did not exit 0"
  assert_contains "$out" "usage:" "--help did not print usage"

  out=$(run_index "$main" --nonsense 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown flag did not exit 2 (got $rc)"

  rc=0
  out=$(run_index "$main" --json --nonsense 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "a typo'd second flag was accepted instead of refused (got $rc)"

  rc=0
  out=$(run_index "$main" --json extra 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "a trailing argument was silently discarded (got $rc)"

  pass "--help prints usage, and an unknown or extra argument is refused"
}

test_grandchild_homes_are_indexed() {
  local main child grandchild out json
  main=$(new_home main-deep)
  child=$(new_home mate-child)
  grandchild=$(new_home mate-grandchild)

  cat > "$main/data/backlog.md" <<'EOF'
## In flight
## Queued
- [ ] deep-main - main item (repo: firstmate) (since 2026-07-01)
## Done
EOF
  cat > "$child/data/backlog.md" <<'EOF'
## In flight
## Queued
- [ ] deep-child - child item (repo: c) (since 2026-07-02)
## Done
EOF
  cat > "$grandchild/data/backlog.md" <<'EOF'
## In flight
- [ ] deep-grandchild - grandchild item (repo: g) (since 2026-07-03)
## Queued
## Done
EOF

  register "$main" childmate "$child"
  register "$child" grandmate "$grandchild"

  out=$(run_index "$main") || fail "run failed on a two-level home tree"
  assert_contains "$out" "deep-grandchild" \
    "a secondmate's own secondmate's work was missing from the index"
  assert_contains "$out" "grandmate" "the grandchild home had no group of its own"

  json=$(run_index "$main" --json) || fail "--json failed on a two-level home tree"
  [ "$(printf '%s' "$json" | jq -r '.totals.homes_read')" = 3 ] \
    || fail "the grandchild home was not counted among the homes read"
  [ "$(printf '%s' "$json" | jq -r '.items[] | select(.id == "deep-grandchild") | .mate')" = grandmate ] \
    || fail "the grandchild's item was not attributed to the grandchild mate"
  [ "$(printf '%s' "$json" | jq -r '.items[] | select(.id == "deep-grandchild") | .home')" \
    = "$(cd "$grandchild" && pwd -P)" ] \
    || fail "the grandchild's item was not attributed to the grandchild home"

  pass "a grandchild home's open work is indexed like any other home's"
}

test_grandchild_without_backlog_is_skipped_by_name() {
  local main child grandchild out json
  main=$(new_home main-deep-skip)
  child=$(new_home mate-deep-ok)
  grandchild=$(new_home mate-deep-bare) # exists, but never gets a backlog

  cat > "$main/data/backlog.md" <<'EOF'
## In flight
## Queued
- [ ] deepskip-main - main item (repo: firstmate) (since 2026-07-01)
## Done
EOF
  cat > "$child/data/backlog.md" <<'EOF'
## In flight
## Queued
- [ ] deepskip-child - child item (repo: c) (since 2026-07-02)
## Done
EOF

  register "$main" okmate "$child"
  register "$child" baremate "$grandchild"

  out=$(run_index "$main") || fail "a bare grandchild home aborted the run"
  assert_contains "$out" "deepskip-child" "the child home dropped out over its bare grandchild"
  assert_contains "$out" "baremate" "the grandchild with no backlog was not named as skipped"

  json=$(run_index "$main" --json) || fail "--json aborted on a bare grandchild home"
  [ "$(printf '%s' "$json" | jq -r '.skipped[] | select(.mate == "baremate") | .reason')" \
    = "no backlog file" ] \
    || fail "the grandchild with no backlog was absent rather than skipped by name"

  pass "a grandchild with no backlog is skipped by name, never silently absent"
}

test_registry_cycle_terminates_with_each_home_once() {
  local main other json count
  main=$(new_home main-cycle)
  other=$(new_home mate-cycle)

  cat > "$main/data/backlog.md" <<'EOF'
## In flight
## Queued
- [ ] cycle-main - main item (repo: firstmate) (since 2026-07-01)
## Done
EOF
  cat > "$other/data/backlog.md" <<'EOF'
## In flight
## Queued
- [ ] cycle-other - other item (repo: o) (since 2026-07-02)
## Done
EOF

  # A registers B and B registers A: the walk must stop, not spin.
  register "$main" cyclemate "$other"
  register "$other" backmate "$main"

  json=$(run_index "$main" --json) || fail "a registry cycle did not terminate cleanly"
  [ "$(printf '%s' "$json" | jq -r '.totals.homes_read')" = 2 ] \
    || fail "a cycle indexed a home more than once"
  [ "$(printf '%s' "$json" | jq -r '.totals.items')" = 2 ] \
    || fail "a cycle double-counted open items"
  count=$(printf '%s' "$json" | jq '[.items[] | select(.id == "cycle-main")] | length')
  [ "$count" = 1 ] || fail "this home's item appeared $count times through the cycle"
  [ "$(printf '%s' "$json" | jq -r '.skipped[] | select(.mate == "backmate") | .reason')" \
    = "home already indexed under another registry id" ] \
    || fail "the repeat visit was not reported as already indexed"

  pass "a registry cycle terminates with every home indexed exactly once"
}

test_free_form_rows_are_counted_in_the_human_heading() {
  local main quiet out
  main=$(new_home main-freeform)
  quiet=$(new_home mate-freeform)

  cat > "$main/data/backlog.md" <<'EOF'
## In flight
- [ ] ff-main - a structured main item (repo: firstmate) (since 2026-07-01)
## Queued
## Done
EOF
  cat > "$quiet/data/backlog.md" <<'EOF'
## In flight
Still thinking about the storage rewrite, nothing filed yet.
## Queued
Maybe revisit the cache someday.
## Done
EOF
  register "$main" prosemate "$quiet"

  out=$(run_index "$main") || fail "run failed on a free-form fixture"
  assert_contains "$out" "0 open items, 2 free-form rows not counted" \
    "free-form rows under In flight/Queued were invisible in the human view"
  printf '%s' "$out" | grep -q '^## main - 1 open item$' \
    || fail "a home with no free-form rows gained the clause anyway"

  pass "free-form rows are named in the human heading, and only when present"
}

test_registry_entry_without_a_home_names_no_fabricated_path() {
  local main out json
  main=$(new_home main-nopath)
  cat > "$main/data/backlog.md" <<'EOF'
## In flight
## Queued
- [ ] nopath-kept - still indexed (repo: firstmate) (since 2026-07-01)
## Done
EOF
  printf -- '- pathless - a mate with no recorded home\n' >> "$main/data/secondmates.md"

  out=$(run_index "$main") || fail "run failed on a registry entry with no home"
  assert_contains "$out" "pathless" "the homeless registry entry was not named as skipped"
  assert_not_contains "$out" "/data/backlog.md" \
    "a fabricated filesystem-root backlog path was printed for a home that has none"

  json=$(run_index "$main" --json) || fail "--json failed on a registry entry with no home"
  [ "$(printf '%s' "$json" | jq -r '.skipped[] | select(.mate == "pathless") | .backlog')" = null ] \
    || fail "--json carried a fabricated backlog path for a home that has none"

  pass "a registry entry with no home names no fabricated backlog path"
}

test_indexes_main_home_and_every_registered_mate
test_missing_backlog_skips_that_home_only
test_unreadable_backlog_skips_that_home_only
test_registry_entry_without_a_home_is_skipped
test_sorted_by_state_then_age
test_grouped_by_mate_with_this_home_first
test_never_writes_to_any_home
test_no_registered_mates_still_indexes_this_home
test_seeded_home_labels_its_own_group_by_name
test_help_and_bad_flag
test_grandchild_homes_are_indexed
test_grandchild_without_backlog_is_skipped_by_name
test_registry_cycle_terminates_with_each_home_once
test_free_form_rows_are_counted_in_the_human_heading
test_registry_entry_without_a_home_names_no_fabricated_path

echo "ALL TESTS PASSED"
