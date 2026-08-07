#!/usr/bin/env bash
# Behavior tests for the "doing"/status-detail publish cap: the character
# budget a worker's published status text must already fit inside without
# needing a downstream renderer to elide it. The cap and its number are
# sourced in bin/fm-classify-lib.sh (FM_DOING_CHAR_CAP, from
# data/herdr-card-iteration-2/report.md's measured fit ladder).
#
# Two layers are covered:
#   (a) fm_doing_truncate - the shared bash helper (fm-classify-lib.sh),
#       exercised directly.
#   (b) fm-fleet-snapshot.sh --json end to end - a task whose status line
#       carries a too-long detail comes back with tasks[].current_state.detail
#       already capped, while a normal-length one passes through unchanged.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-classify-lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-doing-cap)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# --- (a) fm_doing_truncate, direct -----------------------------------------

test_short_text_passes_through_unchanged() {
  local input out
  input="Refactor work cards with improved chip icons and typography"  # 59 chars, the report's own longest real sample
  [ "${#input}" -eq "$FM_DOING_CHAR_CAP" ] || fail "fixture no longer matches the sourced cap ($FM_DOING_CHAR_CAP): ${#input}"
  out=$(fm_doing_truncate "$input")
  [ "$out" = "$input" ] || fail "at-cap text must pass through byte-for-byte, got: $out"
  pass "text at exactly the cap passes through unchanged"
}

test_well_under_cap_passes_through_unchanged() {
  local input out
  input="Ship the thing"
  out=$(fm_doing_truncate "$input")
  [ "$out" = "$input" ] || fail "short text must pass through unchanged, got: $out"
  pass "text well under the cap passes through unchanged"
}

test_long_text_truncates_at_word_boundary() {
  local input out
  input="Refactor work cards with improved chip icons and typography and also update the changelog docs thoroughly"
  out=$(fm_doing_truncate "$input")
  [ "${#out}" -le $((FM_DOING_CHAR_CAP + 1)) ] || fail "truncated output must fit cap+ellipsis, got ${#out} chars: $out"
  case "$out" in
    *…) : ;;
    *) fail "truncated output must end with an ellipsis marker, got: $out" ;;
  esac
  # Word-boundary cut: strip the ellipsis and confirm what remains is a
  # whitespace-clean PREFIX of the original text (never a word sliced in
  # half), which is only possible if the cut landed on a space.
  local body=${out%…}
  case "$input" in
    "$body"*) : ;;
    *) fail "expected a word-boundary prefix of the input, got: $body" ;;
  esac
  case "$input" in
    "$body "*|"$body") : ;;
    *) fail "cut must land exactly at a space, not mid-word: '$body' against '$input'" ;;
  esac
  pass "long text is shortened at the last whole word instead of hard-cut mid-word"
}

test_single_long_token_falls_back_to_hard_cut() {
  local input out expect
  input="Supercalifragilisticexpialidocioussupercalifragilisticexpialidocioussupercalifragilisticexpialidocious"
  out=$(fm_doing_truncate "$input")
  expect="${input:0:$FM_DOING_CHAR_CAP}…"
  [ "$out" = "$expect" ] || fail "no word boundary exists, so it must hard-cut at the cap, got: $out"
  pass "a single token with no early space falls back to a hard cut at the cap"
}

test_whitespace_is_collapsed_before_measuring() {
  local input out
  input=$'line one\nwith   extra   spaces'
  out=$(fm_doing_truncate "$input")
  [ "$out" = "line one with extra spaces" ] || fail "whitespace must collapse to single spaces, got: $out"
  pass "runs of whitespace collapse to one space before the cap is measured"
}

# --- (b) fm-fleet-snapshot.sh --json, end to end ----------------------------

make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

# Two secondmate tasks (secondmate kind skips the busy-pane check and reads
# straight off the status log, so the published detail is exactly the text
# after the status verb - the same free text a crewmate would write).
write_fixture() {  # <home>
  local home=$1
  mkdir -p "$home/projects/short-wt" "$home/projects/long-wt"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] short-doing - Short doing task (repo: alpha) (kind: secondmate) (since 2026-08-04)
- [ ] long-doing - Long doing task (repo: alpha) (kind: secondmate) (since 2026-08-04)
EOF
  fm_write_meta "$home/state/short-doing.meta" \
    "window=firstmate:fm-short-doing" \
    "worktree=$home/projects/short-wt" \
    "project=alpha" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home/projects/short-wt" \
    "projects=alpha"
  printf 'working: Refactor work cards with improved chip icons and typography\n' \
    > "$home/state/short-doing.status"
  fm_write_meta "$home/state/long-doing.meta" \
    "window=firstmate:fm-long-doing" \
    "worktree=$home/projects/long-wt" \
    "project=alpha" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home/projects/long-wt" \
    "projects=alpha"
  printf 'working: Refactor work cards with improved chip icons and typography and also update the changelog docs thoroughly\n' \
    > "$home/state/long-doing.status"
}

test_snapshot_passes_through_a_normal_length_detail() {
  local home fakebin out detail
  home=$(make_home normal)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  detail=$(printf '%s' "$out" | jq -r '.tasks[] | select(.id == "short-doing") | .current_state.detail')
  [ "$detail" = "Refactor work cards with improved chip icons and typography" ] \
    || fail "normal-length detail must pass through unchanged, got: $detail"
  pass "fm-fleet-snapshot.sh passes a normal-length doing detail through unchanged"
}

test_snapshot_shortens_a_too_long_detail() {
  local home fakebin out detail
  home=$(make_home overlong)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  detail=$(printf '%s' "$out" | jq -r '.tasks[] | select(.id == "long-doing") | .current_state.detail')
  [ "${#detail}" -le $((FM_DOING_CHAR_CAP + 1)) ] \
    || fail "published detail must respect the sourced cap, got ${#detail} chars: $detail"
  case "$detail" in
    *…) : ;;
    *) fail "an over-cap detail must be marked as shortened, got: $detail" ;;
  esac
  case "$detail" in
    *changelog*) fail "must not run past the sourced cap keeping full original text: $detail" ;;
  esac
  pass "fm-fleet-snapshot.sh shortens an over-cap doing detail to the sourced budget"
}

test_short_text_passes_through_unchanged
test_well_under_cap_passes_through_unchanged
test_long_text_truncates_at_word_boundary
test_single_long_token_falls_back_to_hard_cut
test_whitespace_is_collapsed_before_measuring
test_snapshot_passes_through_a_normal_length_detail
test_snapshot_shortens_a_too_long_detail

echo "all fm-doing-cap tests passed"
