#!/usr/bin/env bash
# Resolve (and optionally install) the chrome-devtools-mcp build that crewmate
# browser work is pinned to.
#
# Usage: fm-browser-mcp-pin.sh [path]     print the resolved pin entry point
#        fm-browser-mcp-pin.sh --ensure   install the pinned build if absent, then print it
#        fm-browser-mcp-pin.sh --version  print the pinned chrome-devtools-mcp version
#        fm-browser-mcp-pin.sh --help
#
# Exit codes for `path` and `--ensure`:
#   0  a pin resolved; its absolute entry point is on stdout
#   2  no pin resolved; an actionable reason is on stderr (stdout empty)
#   3  the pin is deliberately lifted (the configured pin is "off");
#      stdout empty, nothing printed on stderr. Callers treat this as "no pin
#      wanted", not as a failure.
#
# Why this exists
# ---------------
# chrome-devtools-axi resolves its MCP transport in three steps
# (resolveTransportSpec, dist/src/bridge.js in the installed package, which ships
# only dist/): an explicit CHROME_DEVTOOLS_AXI_MCP_PATH always wins; otherwise it
# auto-detects a global install at
# $(npm prefix -g)/lib/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js;
# only with neither does it fall back to `npx -y chrome-devtools-mcp@latest`. An
# unpinned worker therefore gets whichever of those last two the host happens to
# have, and both are broken from 1.8.0 on.
# chrome-devtools-mcp 1.8.0 made `pageId` a required argument on take_snapshot and
# evaluate_script; chrome-devtools-axi 0.1.27 never sends it, so every bridge that
# starts fresh against such a build fails every snapshot, eval, click, fill and type with
#   MCP error -32602: Input validation error: Invalid arguments for tool take_snapshot: Required at pageId
# while navigation-only commands keep working. A bridge started before 1.8.0 was
# published keeps running fine, which is what makes the breakage look intermittent
# rather than total.
# The upstream argument change is upstream's to reconcile. What firstmate controls is
# which build its own workers launch against, so it pins one known-good build onto
# every worker launch line (bin/fm-spawn.sh) instead of letting each worktree
# rediscover the failure. Lift the pin by writing "off" into config/browser-mcp-pin
# once chrome-devtools-axi sends pageId; no code change is needed for that.
#
# The pin is resolved per home. bin/fm-spawn.sh forwards a resolved pin onto the
# launch lines of the workers this home runs - crewmates and scouts - but not onto
# a secondmate launch line, because a secondmate runs its own FM_HOME and calls this
# script itself at its own dispatch. A secondmate home's config/browser-mcp-pin is
# therefore genuinely that home's durable choice, for it and for the crew it
# dispatches, rather than something the home that spawned it decided.
#
# Resolution order (most to least specific)
#   1. An inherited CHROME_DEVTOOLS_AXI_MCP_PATH - an explicit in-the-moment choice
#      by whoever launched firstmate; honored when it names a file.
#   2. FM_BROWSER_MCP_PIN - a firstmate-scoped override for one process tree,
#      holding either "off" or a path, read exactly like the config file below.
#   3. config/browser-mcp-pin in the resolved FM_HOME - that home's durable choice.
#      "off" lifts the pin (exit 3), whatever whitespace surrounds it; any other
#      content is read as a path to a chrome-devtools-mcp entry point and must exist.
#   4. The fleet-managed install under the pin root, if present.
#   5. Nothing: exit 2 naming the `--ensure` command that would install it.
#
# The pin root defaults to ${XDG_CACHE_HOME:-$HOME/.cache}/firstmate/browser-mcp so a
# single install serves every home on the host; FM_BROWSER_MCP_ROOT overrides it
# (tests pin it to a temp directory so a resolved launch line never depends on
# whatever the developer's own cache happens to hold).
#
# Whichever rank answers, the printed path is always absolute and physical. It is
# read by a crewmate pane whose cwd is its own worktree, not firstmate's, so a
# relative pin that resolved here would name nothing there - and a bridge that
# cannot spawn its transport at all fails even navigation, which is worse than the
# unpinned breakage this exists to fix.
#
# `--ensure` runs a real `npm install` and is therefore never called from the spawn
# path, which stays read-only and fast; firstmate or the captain runs it once per host.
# npm never reifies into the live prefix. It installs into a private staging directory
# beside it, the entry point is verified there, and only a completed tree is published
# with a single rename. Two consequences the rest of this script depends on:
#   - `[ -f "$entry" ]` means a finished install, never a half-extracted one. A killed
#     or failed `--ensure` leaves the live prefix exactly as it was, so a worker can
#     never be pinned onto a tree whose dependencies never landed - which would stop
#     the bridge from starting at all.
#   - Concurrent runs need no mutex. The dispatch diagnostic names this command to
#     every home on the host, so two of them running it in the same minute is ordinary;
#     each stages its own tree, one rename wins, and the run whose rename loses
#     discards its staging copy and reports the winner's entry point with exit 0.
set -u

# The last chrome-devtools-mcp release whose take_snapshot/evaluate_script schemas
# work with the argument set chrome-devtools-axi 0.1.27 sends. Raise this only
# after verifying a newer build against a real bridge.
PIN_VERSION=1.7.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# FM_HOME resolution: see bin/fm-home-anchor-lib.sh ("Why this exists").
# shellcheck source=bin/fm-home-anchor-lib.sh
. "$SCRIPT_DIR/fm-home-anchor-lib.sh"
fm_home_anchor_resolve "$FM_ROOT" || exit 1
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

pin_root() {
  if [ -n "${FM_BROWSER_MCP_ROOT:-}" ]; then
    printf '%s' "$FM_BROWSER_MCP_ROOT"
    return
  fi
  printf '%s' "${XDG_CACHE_HOME:-$HOME/.cache}/firstmate/browser-mcp"
}

# The entry point npm lays down under an install prefix, relative to that prefix.
# chrome-devtools-mcp ships this path in every release in the supported range.
ENTRY_REL=node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js

pin_entry_point() {
  printf '%s/%s/%s' "$(pin_root)" "$PIN_VERSION" "$ENTRY_REL"
}

# The staging directory this run owns, if any, so an interrupted `--ensure` takes
# its half-built tree with it instead of leaving it in a cache directory nobody
# looks at. Empty on the read-only `path` route, which creates nothing.
STAGED_DIR=

discard_staged() {
  [ -n "$STAGED_DIR" ] || return 0
  rm -rf "$STAGED_DIR"
  STAGED_DIR=
}
trap discard_staged EXIT
trap 'discard_staged; exit 130' INT
trap 'discard_staged; exit 143' TERM

# The home's configured pin: FM_BROWSER_MCP_PIN when set, otherwise the first
# non-empty, non-comment line of config/browser-mcp-pin. Empty when neither is set.
# Surrounding whitespace is stripped from either source before it is returned, the
# same rule secondmate_line applies in bin/fm-harness.sh: both are one-line files a
# human is told to edit by hand, so an editor's stray space must not change what
# the value means.
configured_pin() {
  local file=$CONFIG/browser-mcp-pin line env_pin
  if [ -n "${FM_BROWSER_MCP_PIN:-}" ]; then
    env_pin=$FM_BROWSER_MCP_PIN
    env_pin="${env_pin#"${env_pin%%[![:space:]]*}"}"
    env_pin="${env_pin%"${env_pin##*[![:space:]]}"}"
    printf '%s' "$env_pin"
    return 0
  fi
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      ''|'#'*) continue ;;
    esac
    printf '%s' "$line"
    return 0
  done < "$file"
}

# Print a resolved pin in absolute physical form, whatever rank produced it.
# CDPATH is cleared so a stray setting in the invoking shell cannot redirect the
# cd into an unrelated directory of the same name.
emit_pin() {
  local path=$1 dir base abs_dir
  dir=$(dirname -- "$path")
  base=$(basename -- "$path")
  if ! abs_dir=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P); then
    echo "fm-browser-mcp-pin: the resolved pin cannot be made absolute: $path" >&2
    return 2
  fi
  case "$abs_dir" in
    /) printf '/%s\n' "$base" ;;
    *) printf '%s/%s\n' "$abs_dir" "$base" ;;
  esac
}

resolve_pin() {
  local configured inherited entry
  inherited=${CHROME_DEVTOOLS_AXI_MCP_PATH:-}
  configured=$(configured_pin)

  if [ -n "$inherited" ]; then
    if [ -f "$inherited" ]; then
      emit_pin "$inherited"
      return
    fi
    echo "fm-browser-mcp-pin: inherited CHROME_DEVTOOLS_AXI_MCP_PATH does not name a file: $inherited" >&2
    return 2
  fi

  case "$configured" in
    '') ;;
    off|OFF|Off)
      return 3
      ;;
    *)
      if [ -f "$configured" ]; then
        emit_pin "$configured"
        return
      fi
      echo "fm-browser-mcp-pin: the configured pin names a missing file: $configured" >&2
      return 2
      ;;
  esac

  entry=$(pin_entry_point)
  if [ -f "$entry" ]; then
    emit_pin "$entry"
    return
  fi
  echo "fm-browser-mcp-pin: chrome-devtools-mcp $PIN_VERSION is not installed at $entry; browser work will fall back to whatever chrome-devtools-mcp the host resolves - a global install, or npx @latest - which is broken from 1.8.0 on. Install it with: $SCRIPT_DIR/fm-browser-mcp-pin.sh --ensure" >&2
  return 2
}

# Sweep staging directories no live install could still own.
sweep_abandoned_staging() {
  local root=$1
  find "$root" -maxdepth 1 -type d -name ".$PIN_VERSION.staging.*" -mmin +60 \
    -exec rm -rf {} + 2>/dev/null || true
}

# Move a verified staging tree into the live prefix. mv is a plain rename while the
# destination does not exist, which is exactly the property this relies on: the
# entry point becomes visible complete or not at all. If another run published
# first the destination does exist and mv would put our tree inside it instead, so
# the nested copy is recognized by its own unique name and discarded - the tree the
# winner published is never touched. Returns 1 when this run did not publish.
publish_staged() {
  local staged=$1 live=$2 nested
  nested="$live/$(basename "$staged")"
  [ -e "$live" ] && return 1
  mv "$staged" "$live" 2>/dev/null || return 1
  STAGED_DIR=
  if [ -d "$nested" ]; then
    rm -rf "$nested"
    return 1
  fi
  return 0
}

# npm install into an already-created staging directory. Prints nothing on success.
install_staged() {
  local staged=$1 log npm_status
  # A private prefix with its own package.json keeps the install self-contained and
  # keeps npm from walking up into an unrelated project's manifest.
  printf '%s\n' '{"name":"firstmate-browser-mcp-pin","private":true}' > "$staged/package.json" || {
    echo "fm-browser-mcp-pin: could not write the staging manifest in $staged" >&2
    return 2
  }
  # npm's own output is the only thing that separates an offline registry from a
  # proxy rejection, an EACCES cache or an unreachable version, and --ensure is the
  # one command the dispatch diagnostic tells a human to run - so keep it for the
  # failure branch. Captured rather than passed through so the success path stays
  # quiet and stdout stays the entry point alone.
  log=$(mktemp "${TMPDIR:-/tmp}/fm-browser-mcp-pin.XXXXXX") || {
    echo "fm-browser-mcp-pin: could not create a temp file for the npm install log" >&2
    return 2
  }
  (cd "$staged" && npm install --no-audit --no-fund "chrome-devtools-mcp@$PIN_VERSION") >"$log" 2>&1
  npm_status=$?
  if [ "$npm_status" -ne 0 ]; then
    echo "fm-browser-mcp-pin: npm install chrome-devtools-mcp@$PIN_VERSION failed (exit $npm_status); npm said:" >&2
    cat "$log" >&2
    rm -f "$log"
    return 2
  fi
  rm -f "$log"
  if [ ! -f "$staged/$ENTRY_REL" ]; then
    echo "fm-browser-mcp-pin: npm install chrome-devtools-mcp@$PIN_VERSION reported success but left no $ENTRY_REL" >&2
    return 2
  fi
  return 0
}

ensure_pin() {
  local status entry root live
  resolve_pin >/dev/null 2>&1
  status=$?
  case "$status" in
    0) resolve_pin; return 0 ;;
    3) return 3 ;;
  esac

  # Only the fleet-managed location is ours to create. A configured or inherited
  # path that does not exist is somebody's explicit choice pointing at nothing;
  # installing something else underneath it would hide that, so report instead.
  # (configured_pin covers both FM_BROWSER_MCP_PIN and config/browser-mcp-pin.)
  if [ -n "${CHROME_DEVTOOLS_AXI_MCP_PATH:-}" ] || [ -n "$(configured_pin)" ]; then
    resolve_pin
    return 2
  fi

  root=$(pin_root)
  live="$root/$PIN_VERSION"
  entry=$(pin_entry_point)
  if ! command -v npm >/dev/null 2>&1; then
    echo "fm-browser-mcp-pin: npm is not on PATH; cannot install chrome-devtools-mcp $PIN_VERSION" >&2
    return 2
  fi
  mkdir -p "$root" || {
    echo "fm-browser-mcp-pin: could not create $root" >&2
    return 2
  }
  sweep_abandoned_staging "$root"

  STAGED_DIR=$(mktemp -d "$root/.$PIN_VERSION.staging.XXXXXX") || {
    echo "fm-browser-mcp-pin: could not create a staging directory under $root" >&2
    return 2
  }
  if ! install_staged "$STAGED_DIR"; then
    discard_staged
    return 2
  fi
  if publish_staged "$STAGED_DIR" "$live"; then
    emit_pin "$entry"
    return
  fi

  # Another run published while this one was staging, which is the ordinary
  # outcome of two homes acting on the same dispatch diagnostic.
  discard_staged
  if [ -f "$entry" ]; then
    emit_pin "$entry"
    return
  fi
  echo "fm-browser-mcp-pin: $live already exists but holds no $ENTRY_REL; remove it and rerun --ensure" >&2
  return 2
}

case "${1:-path}" in
  path)
    resolve_pin
    ;;
  --ensure)
    ensure_pin
    ;;
  --version)
    printf '%s\n' "$PIN_VERSION"
    ;;
  -h|--help)
    usage
    ;;
  *)
    echo "fm-browser-mcp-pin: unknown argument '$1'" >&2
    usage >&2
    exit 64
    ;;
esac
