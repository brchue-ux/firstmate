#!/usr/bin/env bash
# fm-browser-session-lib.sh - the single owner of the chrome-devtools-axi
# session name firstmate pins to a task.
#
# The bridge chrome-devtools-axi starts detaches itself from the pane at
# startup, so the session NAME is the only handle anything keeps on it
# afterwards. bin/fm-brief.sh writes that name into the generated brief,
# bin/fm-teardown.sh stops exactly that session, and bin/fm-browser-sweep.sh
# derives it back for every open task in the fleet to decide which sessions are
# still owned. Three independent copies of one rule is precisely the drift the
# repo's one-owner rule forbids: a name teardown cannot stop is a bridge that
# leaks, and a name the sweep cannot match is a live worker's browser reported
# as an orphan.
#
# The name is `fm-<task id>` whenever that fits, which is the overwhelmingly
# common case and is what keeps a flagged session attributable to its task by
# reading it. chrome-devtools-axi's validateSessionName accepts 1-64 characters
# from [A-Za-z0-9._-], while bin/fm-pr-lib.sh admits a task id of up to 64
# characters from that same alphabet, so `fm-<id>` can reach 67 - and a name
# over the cap is refused on EVERY call, which blocks the task's browser work
# outright and makes teardown's scoped stop a permanent no-op. A name that would
# exceed the cap therefore keeps as much of the leading id as still fits and
# carries the uniqueness in a short hash of the WHOLE id, so two ids sharing a
# long prefix still get distinct sessions. Nothing hashes when it does not have
# to: a digest of hashed names would destroy the operator-readable attribution
# this pinning exists to create.
#
# The derivation is a pure function of the task id - no clock, no environment,
# no filesystem - so every process on a host computes the same name for the same
# task. Which digest tool is available decides the hash, exactly as
# bin/fm-backend-hometag-lib.sh already accepts, and a session name is only ever
# compared against names derived on the same host.

FM_BROWSER_SESSION_PREFIX="fm-"
# chrome-devtools-axi's own cap (src/sessions.js validateSessionName).
FM_BROWSER_SESSION_NAME_MAX=64

# Short stable digest of $1. Tool preference matches
# bin/fm-backend-hometag-lib.sh so the fleet has one spelling of "short hash".
fm_browser_session_hash() {  # <text>
  local text=${1-}
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$text" | shasum -a 256 | awk '{print substr($1, 1, 8)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$text" | sha256sum | awk '{print substr($1, 1, 8)}'
  else
    printf '%s' "$text" | cksum | awk '{printf "%08x", $1}'
  fi
}

# The pinned session name for a task id, or non-zero when one cannot be derived
# at all (no id, or no digest to shorten with). Callers treat a non-zero return
# as "this task has no browser session", never as "use the raw id".
fm_browser_session_name() {  # <task-id>
  local id=${1-} name hash keep
  [ -n "$id" ] || return 1
  name="$FM_BROWSER_SESSION_PREFIX$id"
  if [ "${#name}" -le "$FM_BROWSER_SESSION_NAME_MAX" ]; then
    printf '%s\n' "$name"
    return 0
  fi
  hash=$(fm_browser_session_hash "$id")
  case "$hash" in
    '' | *[!0-9a-f]*) return 1 ;;
  esac
  # One separator between the kept prefix and the hash, so the shortened form
  # reads as a truncation rather than as a different id.
  keep=$((FM_BROWSER_SESSION_NAME_MAX - ${#FM_BROWSER_SESSION_PREFIX} - 1 - ${#hash}))
  [ "$keep" -ge 1 ] || return 1
  printf '%s%s-%s\n' "$FM_BROWSER_SESSION_PREFIX" "${id:0:keep}" "$hash"
}
