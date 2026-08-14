#!/usr/bin/env bash
# Behavior tests for bin/fm-project-mode.sh's registry parse.
#
# The script prints "<mode> <yolo> <base>" for one project. mode and yolo drive
# delivery posture; base names the git remote that carries the project's real
# working line and defaults to "origin", so bin/fm-fleet-sync.sh stops comparing
# a fork-line clone against a remote nobody pushes to.
#
# These cases pin the token contract every caller depends on: tokens inside the
# bracket group are order-independent, an absent base is "origin" rather than
# empty, and a base that git could misread (an option-looking or path-looking
# value) is refused back to origin with a warning instead of being handed to
# `git fetch`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-mode)
HOME_N=0

# new_home: a fresh isolated FM_HOME with an empty data/ dir.
new_home() {
  HOME_N=$((HOME_N + 1))
  local h="$TMP_ROOT/home-$HOME_N"
  mkdir -p "$h/data"
  printf '%s\n' "$h"
}

# home_with <line...>: a home whose registry holds the given entry lines.
home_with() {
  local home
  home=$(new_home)
  printf '%s\n' "$@" > "$home/data/projects.md"
  printf '%s\n' "$home"
}

# expect_mode <home> <project> <expected>: assert the exact printed contract.
expect_mode() {
  local home=$1 project=$2 expected=$3 out
  out=$(FM_HOME="$home" "$MODE" "$project" 2>/dev/null)
  [ "$out" = "$expected" ] || fail "expected \"$expected\" for $project, got \"$out\""
}

test_legacy_and_mode_only_entries_default_to_origin() {
  local home
  home=$(home_with \
    '- plain - legacy entry with no bracket group (added 2026-08-13)' \
    '- moded [direct-PR] - mode only (added 2026-08-13)' \
    '- yolod [direct-PR +yolo] - mode and yolo (added 2026-08-13)')

  expect_mode "$home" plain "no-mistakes off origin"
  expect_mode "$home" moded "direct-PR off origin"
  expect_mode "$home" yolod "direct-PR on origin"
  pass "entries without base= keep their mode and yolo and report origin"
}

test_base_token_is_parsed_in_any_position() {
  local home
  home=$(home_with \
    '- forked [direct-PR base=fork] - fork line (added 2026-08-13)' \
    '- both [direct-PR +yolo base=fork] - fork line, yolo (added 2026-08-13)' \
    '- reordered [base=fork +yolo direct-PR] - tokens out of order (added 2026-08-13)' \
    '- baseonly [base=fork] - base only, default mode (added 2026-08-13)')

  expect_mode "$home" forked "direct-PR off fork"
  expect_mode "$home" both "direct-PR on fork"
  expect_mode "$home" reordered "direct-PR on fork"
  expect_mode "$home" baseonly "no-mistakes off fork"
  pass "base=<remote> is read from any position and never mistaken for the mode"
}

test_invalid_base_falls_back_to_origin_loudly() {
  local home out
  home=$(home_with \
    '- empty [direct-PR base=] - empty base (added 2026-08-13)' \
    '- optionish [direct-PR base=--upload-pack=touch] - option-looking base (added 2026-08-13)' \
    '- pathish [direct-PR base=../evil] - path-looking base (added 2026-08-13)')

  expect_mode "$home" empty "direct-PR off origin"
  expect_mode "$home" optionish "direct-PR off origin"
  expect_mode "$home" pathish "direct-PR off origin"

  out=$(FM_HOME="$home" "$MODE" optionish 2>&1 >/dev/null)
  assert_contains "$out" "invalid base remote" "an unusable base remote warns to stderr"
  pass "a base remote git could misread is refused back to origin with a warning"
}

test_absent_project_and_registry_report_origin() {
  local home out
  home=$(home_with '- known [direct-PR base=fork] - fork line (added 2026-08-13)')

  expect_mode "$home" unknown-project "no-mistakes off origin"
  out=$(FM_HOME="$home" "$MODE" unknown-project 2>&1 >/dev/null)
  assert_contains "$out" "not in registry" "an unregistered project still warns"

  home=$(new_home)
  expect_mode "$home" anything "no-mistakes off origin"
  pass "a missing project or missing registry falls back to the safe default with origin"
}

# The base remote is a third output word, so a caller that reads exactly two
# fields absorbs it. bin/fm-spawn.sh is that caller: it persists the yolo flag
# into state/<id>.meta, which every later authority decision reads, so a
# "yolo=on fork" line would be a corrupt delivery posture for any project that
# records a base remote. Drive the real spawn for such a project and assert the
# posture it records is still exactly the registry's mode and yolo.
test_spawn_records_uncorrupted_posture_for_a_base_remote_project() {
  local home proj fakebin out meta
  home=$(new_home)
  mkdir -p "$home/data/t1" "$home/state" "$home/config" "$home/projects"
  printf 'brief\n' > "$home/data/t1/brief.md"
  printf -- '- forked [direct-PR +yolo base=fork] - fork line (added 2026-08-13)\n' \
    > "$home/data/projects.md"
  proj="$home/projects/forked"
  git init -q -b main "$proj"
  git -C "$proj" commit -q --allow-empty -m init
  # fm-spawn refuses a non-isolated worktree, so give it a real linked one.
  git -C "$proj" worktree add -q --detach "$home/wt" >/dev/null 2>&1

  fakebin=$(fm_fakebin "$home/fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$home/wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" t1 "$proj" codex 2>&1) \
    || fail "spawn failed for a project with a base remote: $out"

  assert_contains "$out" "mode=direct-PR yolo=on window=" \
    "the spawn line carried the base remote into the yolo field"
  meta="$home/state/t1.meta"
  [ -f "$meta" ] || fail "spawn wrote no task metadata"
  [ "$(grep -c '^yolo=on$' "$meta")" = 1 ] \
    || fail "task metadata did not record a clean yolo flag: $(grep '^yolo=' "$meta")"
  [ "$(grep -c '^mode=direct-PR$' "$meta")" = 1 ] \
    || fail "task metadata did not record the registry mode: $(grep '^mode=' "$meta")"
  pass "a spawn for a base=<remote> project records the registry's posture uncorrupted"
}

test_legacy_and_mode_only_entries_default_to_origin
test_base_token_is_parsed_in_any_position
test_invalid_base_falls_back_to_origin_loudly
test_absent_project_and_registry_report_origin
test_spawn_records_uncorrupted_posture_for_a_base_remote_project
