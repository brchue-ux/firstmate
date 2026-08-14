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

# Bridge identity, shared by everything in bin/ that acts on a recorded pid.
#
# The marker is the BRIDGE entry point, not the package name: a plain
# `chrome-devtools-axi <cmd>` CLI call carries the package name in its argv too.
# This is the tool's own definition (dist/src/client.js isBridgeProcess).
FM_BROWSER_SESSION_BRIDGE_MARKER=chrome-devtools-axi-bridge

# The state root chrome-devtools-axi keeps its records under. The tool derives
# this from the home directory with no environment override of its own
# (dist/src/sessions.js resolveSessionStateDir), so the override here exists for
# tests and one-off manual runs rather than as a configuration surface.
fm_browser_session_root() {
  printf '%s\n' "${FM_BROWSER_SESSION_ROOT:-${HOME:-}/.chrome-devtools-axi}"
}

# A session's own state directory. The default session keeps the legacy state
# root itself; every named session lives under sessions/<name>.
fm_browser_session_state_dir() {  # <session> [state-root]
  local session=$1 root=${2:-}
  [ -n "$root" ] || root=$(fm_browser_session_root)
  if [ "$session" = default ]; then
    printf '%s\n' "$root"
  else
    printf '%s\n' "$root/sessions/$session"
  fi
}

# The pid chrome-devtools-axi recorded for a bridge, from its {"pid":N,"port":P}
# record. Read without a jq dependency, and anything that does not parse to a
# plain number is unreadable rather than guessed at.
fm_browser_session_bridge_pid() {  # <bridge.pid path>
  local file=$1 pid
  pid=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$file" 2>/dev/null | head -n 1)
  case "$pid" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$pid"
}

# Whether a pid is alive AND is still this tool's bridge. A pid the OS has
# reused is not ours, and neither is a short-lived CLI call.
fm_browser_session_is_bridge() {  # <pid>
  local pid=$1 args
  kill -0 "$pid" 2>/dev/null || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  case "$args" in
    *"$FM_BROWSER_SESSION_BRIDGE_MARKER"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Whether a session's own record names a live bridge process right now.
#
# This is the precondition for acting on that record. The tool's own `stop`
# reads the pid file, checks only that the pid is ALIVE, and then SIGTERMs and
# SIGKILLs it - the bridge-identity test gates nothing but whether the process
# group goes too. So a stale bridge.pid whose number the OS has since handed to
# something else is a live process killed by a cleanup that thought it was
# closing its own browser. A stale record is the ordinary aftermath of any
# bridge that crashed or was killed rather than stopped, and pid reuse is
# routine wherever pid_max is small.
#
# Nothing is lost by asking first: with no record, or a pid that is not alive,
# the tool's own stop is already a no-op.
fm_browser_session_has_live_bridge() {  # <session> [state-root]
  local session=$1 root=${2:-} dir pid
  [ -n "$session" ] || return 1
  dir=$(fm_browser_session_state_dir "$session" "$root")
  [ -f "$dir/bridge.pid" ] || return 1
  pid=$(fm_browser_session_bridge_pid "$dir/bridge.pid") || return 1
  fm_browser_session_is_bridge "$pid"
}
