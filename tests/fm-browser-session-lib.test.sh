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
    name=$(fm_browser_session_name "$id") || fail "no name derived for '$id'"
    [ "$name" = "fm-$id" ] \
      || fail "an id that fits was renamed: expected fm-$id, got $name"
    assert_valid_session_name "$name" "$id"
  done
  # 61 characters is the longest id whose fm- form still lands exactly on the
  # cap, so it must not be shortened either.
  id=$(task_id_of_length 61)
  name=$(fm_browser_session_name "$id")
  [ "$name" = "fm-$id" ] && [ "${#name}" -eq "$MAX" ] \
    || fail "the longest id that still fits was shortened: $name (${#name} chars)"
  pass "fm-browser-session-lib: an id that fits keeps the byte-identical fm-<id> name operators read attribution from"
}

test_oversized_ids_are_shortened_under_the_cap() {
  local len id name
  for len in 62 63 64; do
    id=$(task_id_of_length "$len")
    [ "${#id}" -eq "$len" ] || fail "fixture id is ${#id} characters, wanted $len"
    name=$(fm_browser_session_name "$id") || fail "no name derived for a $len-character id"
    assert_valid_session_name "$name" "$len-character id"
    [ "$name" != "fm-$id" ] \
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

  name_a=$(fm_browser_session_name "$a")
  name_b=$(fm_browser_session_name "$b")
  [ "$name_a" != "$name_b" ] \
    || fail "two different tasks sharing a long prefix collapsed onto one session: $name_a"

  # Every process on the host derives this independently - the brief when the
  # task is dispatched, teardown hours later, the sweep in another session - so
  # a second derivation that differed would mean a bridge nothing can stop.
  again=$(fm_browser_session_name "$a")
  [ "$again" = "$name_a" ] \
    || fail "the same id derived two different names: $name_a then $again"
  pass "fm-browser-session-lib: shortened names are deterministic per id and stay distinct across a shared prefix"
}

test_no_id_yields_no_session() {
  local name
  name=$(fm_browser_session_name "") \
    && fail "an empty task id produced a session name: $name"
  name=$(fm_browser_session_name) \
    && fail "a missing task id produced a session name: $name"
  pass "fm-browser-session-lib: no task id yields no session name, never a bare prefix a stop could match"
}

test_ordinary_ids_keep_their_readable_name
test_oversized_ids_are_shortened_under_the_cap
test_shortened_names_stay_distinct_and_deterministic
test_no_id_yields_no_session
