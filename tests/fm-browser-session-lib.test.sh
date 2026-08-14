#!/usr/bin/env bash
# Behavior tests for the shared chrome-devtools-axi session-name derivation.
#
# Three commands compute this name - bin/fm-brief.sh briefs it, bin/fm-teardown.sh
# stops it, bin/fm-browser-sweep.sh matches it back against open work - so what
# matters is the function's own output, not where it is called from. The limits
# it has to satisfy are both real and both external: chrome-devtools-axi's
# validateSessionName accepts 1-64 characters from [A-Za-z0-9._-] and throws on
# anything else, while bin/fm-pr-lib.sh's fm_task_id_creation_valid admits a task
# id of up to 64 characters, so the naive fm-<id> can be three characters over a
# cap that fails EVERY call the worker makes.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-browser-session-lib.sh disable=SC1091
. "$ROOT/bin/fm-browser-session-lib.sh"

MAX=64
TMP_ROOT=$(fm_test_tmproot fm-browser-session-lib)

# One ordinary main home to derive against. The home is part of every name now,
# so a fixture home is as much an input as the task id is.
HOME_MAIN="$TMP_ROOT/main-home"
mkdir -p "$HOME_MAIN"
HOME_MAIN_TAG=$(fm_browser_session_home_tag "$HOME_MAIN")
# The longest id whose full `fm-<id>-<tag>` still lands on the cap. Computed
# rather than hardcoded, because the tag's length depends on the fixture path.
FITS_MAX=$((MAX - 3 - 1 - ${#HOME_MAIN_TAG}))

# A task id of exactly <n> characters, in the alphabet task ids really use.
task_id_of_length() {  # <n>
  local want=$1 head="long-fleet-task-" tail=""
  while [ $((${#head} + ${#tail})) -lt "$want" ]; do
    tail="${tail}x"
  done
  printf '%s\n' "${head}${tail}"
}

assert_valid_session_name() {  # <name> <label>
  local name=$1 label=$2
  [ -n "$name" ] || fail "$label: derived an empty session name"
  [ "${#name}" -le "$MAX" ] \
    || fail "$label: derived a ${#name}-character name, over chrome-devtools-axi's $MAX cap: $name"
  case "$name" in
    *[!A-Za-z0-9._-]*) fail "$label: derived a name outside [A-Za-z0-9._-]: $name" ;;
  esac
}

test_ordinary_ids_keep_their_readable_name() {
  local id name
  for id in t1 fix-browser-orphan-teardown a.b_-ish; do
    name=$(fm_browser_session_name "$id" "$HOME_MAIN") || fail "no name derived for '$id'"
    [ "$name" = "fm-$id-$HOME_MAIN_TAG" ] \
      || fail "an id that fits was renamed: expected fm-$id-$HOME_MAIN_TAG, got $name"
    assert_valid_session_name "$name" "$id"
  done
  # The longest id that still lands exactly on the cap must not be shortened
  # either.
  id=$(task_id_of_length "$FITS_MAX")
  name=$(fm_browser_session_name "$id" "$HOME_MAIN")
  [ "$name" = "fm-$id-$HOME_MAIN_TAG" ] && [ "${#name}" -eq "$MAX" ] \
    || fail "the longest id that still fits was shortened: $name (${#name} chars)"
  pass "fm-browser-session-lib: an id that fits keeps the byte-identical fm-<id> name operators read attribution from"
}

test_oversized_ids_are_shortened_under_the_cap() {
  local len id name
  for len in $((FITS_MAX + 1)) $((FITS_MAX + 2)) 64; do
    id=$(task_id_of_length "$len")
    [ "${#id}" -eq "$len" ] || fail "fixture id is ${#id} characters, wanted $len"
    name=$(fm_browser_session_name "$id" "$HOME_MAIN") || fail "no name derived for a $len-character id"
    assert_valid_session_name "$name" "$len-character id"
    [ "$name" != "fm-$id-$HOME_MAIN_TAG" ] \
      || fail "a $len-character id kept a name chrome-devtools-axi would refuse: $name"
    # Recognizably still that task: the name opens with as much of the id as
    # survived, so an operator reading a digest line can still place it.
    case "$name" in
      "fm-${id:0:40}"*) : ;;
      *) fail "a shortened name dropped the leading id: $name" ;;
    esac
  done
  pass "fm-browser-session-lib: an id too long for the cap is shortened to a legal name that still opens with the id"
}

test_shortened_names_stay_distinct_and_deterministic() {
  local shared a b name_a name_b again
  shared=$(task_id_of_length 60)
  a="${shared}aaaa"
  b="${shared}bbbb"
  [ "${#a}" -eq 64 ] && [ "${#b}" -eq 64 ] || fail "fixture ids are not 64 characters"

  name_a=$(fm_browser_session_name "$a" "$HOME_MAIN")
  name_b=$(fm_browser_session_name "$b" "$HOME_MAIN")
  [ "$name_a" != "$name_b" ] \
    || fail "two different tasks sharing a long prefix collapsed onto one session: $name_a"

  # Every process on the host derives this independently - the brief when the
  # task is dispatched, teardown hours later, the sweep in another session - so
  # a second derivation that differed would mean a bridge nothing can stop.
  again=$(fm_browser_session_name "$a" "$HOME_MAIN")
  [ "$again" = "$name_a" ] \
    || fail "the same id derived two different names: $name_a then $again"
  pass "fm-browser-session-lib: shortened names are deterministic per id and stay distinct across a shared prefix"
}

# chrome-devtools-axi keeps every session in one directory per OS user, while a
# task id is only unique inside its own home. Two homes that each file
# `readme-refresh` would otherwise pin both crewmates to one bridge - two agents
# driving one Chrome - and the first teardown to finish would SIGKILL the other's
# browser mid-task with no operator in the loop.
test_the_same_id_in_two_homes_is_two_sessions() {
  local home_a home_b mate id=readme-refresh name_a name_b name_mate
  home_a="$TMP_ROOT/collide-a"
  home_b="$TMP_ROOT/collide-b"
  mate="$TMP_ROOT/collide-mate"
  mkdir -p "$home_a" "$home_b" "$mate"
  printf '%s\n' collide-mate > "$mate/.fm-secondmate-home"

  name_a=$(fm_browser_session_name "$id" "$home_a") || fail "no name derived for home A"
  name_b=$(fm_browser_session_name "$id" "$home_b") || fail "no name derived for home B"
  name_mate=$(fm_browser_session_name "$id" "$mate") || fail "no name derived for the secondmate home"

  [ "$name_a" != "$name_b" ] \
    || fail "two homes filing the same task id collapsed onto one browser session: $name_a"
  [ "$name_a" != "$name_mate" ] \
    || fail "a secondmate home shares the primary's session for the same task id: $name_a"
  [ "$name_b" != "$name_mate" ] \
    || fail "two different homes share one session for the same task id: $name_b"
  assert_valid_session_name "$name_a" "home A"
  assert_valid_session_name "$name_mate" "secondmate home"

  # Still attributable: whichever home owns it, the name opens with the task.
  case "$name_a" in
    "fm-$id"*) : ;;
    *) fail "the home tag displaced the task id from the front of the name: $name_a" ;;
  esac
  case "$name_mate" in
    "fm-$id"*) : ;;
    *) fail "the home tag displaced the task id from the front of the name: $name_mate" ;;
  esac

  # Same home, same id, twice: teardown must reach the session the brief pinned
  # hours earlier, so this has to be stable and not merely unique.
  [ "$(fm_browser_session_name "$id" "$home_a")" = "$name_a" ] \
    || fail "the same task in the same home derived two different names"
  pass "fm-browser-session-lib: the same task id in different homes derives different sessions, still led by the task id"
}

# A maximum-length id plus a home tag runs past the cap, which is where the
# shortening rule has to compose with the home rather than replace it.
test_home_stays_distinct_when_the_name_must_be_shortened() {
  local home_a home_b id name_a name_b
  home_a="$TMP_ROOT/long-collide-a"
  home_b="$TMP_ROOT/long-collide-b"
  mkdir -p "$home_a" "$home_b"
  id=$(task_id_of_length 64)

  name_a=$(fm_browser_session_name "$id" "$home_a") || fail "no name derived for a 64-character id"
  name_b=$(fm_browser_session_name "$id" "$home_b") || fail "no name derived for a 64-character id"
  assert_valid_session_name "$name_a" "64-character id, home A"
  assert_valid_session_name "$name_b" "64-character id, home B"
  [ "$name_a" != "$name_b" ] \
    || fail "a shortened name dropped the home, so two homes share one session: $name_a"
  case "$name_a" in
    "fm-${id:0:20}"*) : ;;
    *) fail "a shortened name dropped the leading id: $name_a" ;;
  esac
  pass "fm-browser-session-lib: a name too long for the cap stays distinct per home and still opens with the id"
}

test_no_home_yields_no_session() {
  local name
  name=$( unset FM_HOME; fm_browser_session_name some-task ) \
    && fail "a task with no owning home produced a session name: $name"
  pass "fm-browser-session-lib: no owning home yields no session name, never an unscoped one"
}

test_no_id_yields_no_session() {
  local name
  name=$(fm_browser_session_name "" "$HOME_MAIN") \
    && fail "an empty task id produced a session name: $name"
  name=$(fm_browser_session_name) \
    && fail "a missing task id produced a session name: $name"
  pass "fm-browser-session-lib: no task id yields no session name, never a bare prefix a stop could match"
}

test_ordinary_ids_keep_their_readable_name
test_oversized_ids_are_shortened_under_the_cap
test_shortened_names_stay_distinct_and_deterministic
test_the_same_id_in_two_homes_is_two_sessions
test_home_stays_distinct_when_the_name_must_be_shortened
test_no_home_yields_no_session
test_no_id_yields_no_session
