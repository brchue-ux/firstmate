#!/usr/bin/env bash
# Behavior tests for bin/fm-treehouse-spelling-lib.sh's fm_treehouse_recognized_path.
#
# bin/fm-spawn.sh records every worktree/home path in resolved-real (`pwd -P`)
# form, because that form is what the worktree-isolation assertions elsewhere
# must compare. `treehouse`'s own pool registry instead matches on the literal
# path it leased under, reached through $HOME/.treehouse without resolving
# symlinks. When $HOME/.treehouse is itself a symlink, those two spellings of
# the same directory diverge as strings, and a literal `treehouse return
# --force <resolved-real-path>` refuses with "not managed by treehouse" even
# though the lease is live - confirmed end-to-end against a real symlinked
# $HOME/.treehouse in the environment this fix was diagnosed in (see the PR
# description; not reproduced here).
#
# These cases exercise the helper directly rather than a live treehouse pool:
# a live pool needs the real `treehouse` binary and a real leased worktree,
# neither reproducible hermetically in this test harness. tests/fm-teardown.test.sh
# separately covers the boundary end-to-end through bin/fm-teardown.sh itself,
# with a mock `treehouse` that asserts on the exact spelling it receives.
#
#   (a) $HOME/.treehouse is a symlink: a resolved-real path under the symlink's
#       physical target maps back to the $HOME/.treehouse-spelled form.
#   (b) $HOME/.treehouse is a plain directory (no symlink): no-op, input
#       returned unchanged - the common case sees no behavior change.
#   (c) the path is not under $HOME/.treehouse at all, symlink or not: no-op.
#   (d) TREEHOUSE_ROOT overrides $HOME/.treehouse, same as the `treehouse` CLI
#       itself: mapping is against the override, not the default.
#   (e) a translation is indicated but the candidate cannot be verified to name
#       the same real directory: fails closed - prints nothing, returns non-zero.
#   (f) empty input: fails closed.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-treehouse-spelling-lib.sh disable=SC1091
. "$ROOT/bin/fm-treehouse-spelling-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-treehouse-spelling-lib)

test_symlinked_treehouse_root_maps_to_recognized_spelling() {
  local real_root fixture_home physical result
  real_root="$TMP_ROOT/a/pool-real"
  fixture_home="$TMP_ROOT/a/home"
  mkdir -p "$real_root/slot/wt" "$fixture_home"
  ln -s "$real_root" "$fixture_home/.treehouse"

  physical=$(cd "$real_root/slot/wt" && pwd -P)
  result=$(HOME="$fixture_home" fm_treehouse_recognized_path "$physical") \
    || fail "symlinked root: helper refused a path it should have translated"
  [ "$result" = "$fixture_home/.treehouse/slot/wt" ] \
    || fail "symlinked root: expected $fixture_home/.treehouse/slot/wt, got $result"
  # The spelling must actually resolve back to the same real directory -
  # otherwise this would just be string surgery, not a verified mapping.
  [ "$(cd "$result" && pwd -P)" = "$physical" ] \
    || fail "symlinked root: translated spelling does not resolve to the original real path"
  pass "fm-treehouse-spelling-lib: a resolved-real path under a symlinked \$HOME/.treehouse maps to the spelling treehouse recognizes"
}

test_non_symlinked_treehouse_root_is_a_noop() {
  local fixture_home physical result
  fixture_home="$TMP_ROOT/b/home"
  mkdir -p "$fixture_home/.treehouse/slot/wt"

  physical=$(cd "$fixture_home/.treehouse/slot/wt" && pwd -P)
  result=$(HOME="$fixture_home" fm_treehouse_recognized_path "$physical") \
    || fail "no-symlink case: helper refused a path that needed no translation"
  [ "$result" = "$physical" ] \
    || fail "no-symlink case: expected the input unchanged ($physical), got $result"
  pass "fm-treehouse-spelling-lib: a home whose \$HOME/.treehouse is not a symlink sees no behavior change"
}

test_path_outside_treehouse_root_is_untouched() {
  local real_root fixture_home elsewhere result
  real_root="$TMP_ROOT/c/pool-real"
  fixture_home="$TMP_ROOT/c/home"
  elsewhere="$TMP_ROOT/c/elsewhere/wt"
  mkdir -p "$real_root" "$fixture_home" "$elsewhere"
  ln -s "$real_root" "$fixture_home/.treehouse"

  elsewhere=$(cd "$elsewhere" && pwd -P)
  result=$(HOME="$fixture_home" fm_treehouse_recognized_path "$elsewhere") \
    || fail "outside-root case: helper refused a path it should have left alone"
  [ "$result" = "$elsewhere" ] \
    || fail "outside-root case: expected the input unchanged ($elsewhere), got $result"
  pass "fm-treehouse-spelling-lib: a path outside the (symlinked) treehouse root is left untouched"
}

test_treehouse_root_env_override_is_respected() {
  local real_root override_root physical result
  real_root="$TMP_ROOT/d/pool-real"
  override_root="$TMP_ROOT/d/override-root"
  mkdir -p "$real_root/slot/wt" "$TMP_ROOT/d"
  ln -s "$real_root" "$override_root"

  physical=$(cd "$real_root/slot/wt" && pwd -P)
  # HOME deliberately points somewhere with no .treehouse at all, so a pass
  # here can only be explained by TREEHOUSE_ROOT winning, exactly as the
  # `treehouse` CLI's own --root/TREEHOUSE_ROOT precedence does.
  result=$(HOME="$TMP_ROOT/d/no-such-home" TREEHOUSE_ROOT="$override_root" \
    fm_treehouse_recognized_path "$physical") \
    || fail "TREEHOUSE_ROOT override: helper refused a path it should have translated"
  [ "$result" = "$override_root/slot/wt" ] \
    || fail "TREEHOUSE_ROOT override: expected $override_root/slot/wt, got $result"
  pass "fm-treehouse-spelling-lib: TREEHOUSE_ROOT overrides the default \$HOME/.treehouse, matching the CLI's own precedence"
}

test_unverifiable_candidate_fails_closed() {
  local real_root fixture_home ghost_physical rc out
  real_root="$TMP_ROOT/e/pool-real"
  fixture_home="$TMP_ROOT/e/home"
  mkdir -p "$real_root" "$fixture_home"
  # Canonicalize before use: ghost_physical below is compared against the
  # helper's own pwd -P resolution of the symlink, so its prefix must be
  # built from the same fully-resolved form rather than TMP_ROOT's raw string
  # (which could itself sit behind an unrelated symlink on some hosts).
  real_root=$(cd "$real_root" && pwd -P)
  ln -s "$real_root" "$fixture_home/.treehouse"

  # A path that string-matches under the (symlinked) root's physical prefix but
  # names a directory that does not exist anywhere - through either spelling.
  # The candidate spelling built from it can never be verified, so the helper
  # must refuse rather than hand back an unverified guess.
  ghost_physical="$real_root/ghost-slot/wt"
  set +e
  out=$(HOME="$fixture_home" fm_treehouse_recognized_path "$ghost_physical")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unverifiable candidate: expected a non-zero return, got 0 (output: $out)"
  [ -z "$out" ] || fail "unverifiable candidate: expected no output on failure, got: $out"
  pass "fm-treehouse-spelling-lib: a candidate spelling that cannot be verified fails closed instead of guessing"
}

test_empty_input_fails_closed() {
  local rc out
  set +e
  out=$(fm_treehouse_recognized_path "")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "empty input: expected a non-zero return, got 0 (output: $out)"
  [ -z "$out" ] || fail "empty input: expected no output on failure, got: $out"
  pass "fm-treehouse-spelling-lib: an empty path fails closed"
}

test_symlinked_treehouse_root_maps_to_recognized_spelling
test_non_symlinked_treehouse_root_is_a_noop
test_path_outside_treehouse_root_is_untouched
test_treehouse_root_env_override_is_respected
test_unverifiable_candidate_fails_closed
test_empty_input_fails_closed
