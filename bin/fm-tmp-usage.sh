#!/usr/bin/env bash
# fm-tmp-usage.sh - report how full the shared temp filesystem is, while there
# is still room to act on the answer.
#
# Why this exists: on a typical host /tmp is a small RAM-backed tmpfs, not a
# slice of the main disk - a few gigabytes against a few hundred. Every
# firstmate home, every crewmate, and every tool on the host writes scratch into
# that one small filesystem. When it fills, commands do not fail loudly: temp
# writes fail, and a shell whose redirections and here-documents cannot be
# written starts returning bare failures with no output, which reads as a broken
# agent rather than a full disk (the shell-breakage signature already recorded
# in this fleet's learnings). The 2026-08-11 incident was found only when
# commands stopped working; nothing warned first. This is that warning.
#
# This is the measurement and severity owner only. It decides how full the temp
# root is and which severity that is, and prints one line. It deliberately does
# NOT decide presentation loudness or reclamation:
#   - bin/fm-guard.sh owns loudness. It calls this on the fleet actions that
#     matter (a spawn, a peek, a PR check, a wake drain, session start), keeps
#     one line at "warn", and re-claims a full bordered banner at each higher
#     severity, so a growing problem gets louder instead of staying one quiet
#     warning.
#   - bin/fm-tmp-sweep.sh owns reclamation, and remains the ONLY thing in this
#     repo that removes anything from the temp root. This script never deletes,
#     and never triggers a delete. Session start already sweeps; adding a second
#     destructive trigger here would duplicate a destructive predicate on a hot
#     path, and the biggest consumers in the incident were live session
#     scratchpads mid-build, which are not fleet-owned scratch and must never be
#     removed automatically. Above a threshold this reports loudly and names the
#     sweep; a human decides about everything the sweep refuses.
#
# The check is one `df` on the temp root. It is deliberately not a `du` walk:
# the incident showed `du -sh /tmp` can itself hang or abort on a near-full
# shared root, so the only check worth having is one that cannot be taken out by
# the condition it exists to detect. For the same reason this script writes
# nothing at all - no marker, no cache, no temp file - so a completely full temp
# root cannot disable it.
#
# Usage:
#   fm-tmp-usage.sh [--root <dir>] [--warn <pct>] [--high <pct>]
#                   [--critical <pct>] [--verbose]
#   fm-tmp-usage.sh -h | --help
#
# The default root is ${TMPDIR:-/tmp}, the same root bin/fm-tmp-sweep.sh
# reclaims, so the measured filesystem is always the one this fleet's scratch
# actually lands in. df reports the filesystem CONTAINING the path, so a TMPDIR
# nested inside /tmp still measures the /tmp filesystem.
#
# Output is one line, in the "<subject>: <verb>: <detail>" shape the other
# session-start checks use, and silent below the warn threshold:
#   "<root>: warn: 84% full (1.2G free of 7.4G, warn at 80%)"
#   "<root>: high: 91% full (683M free of 7.4G, high at 90%)"
#   "<root>: critical: 96% full (301M free of 7.4G, critical at 95%)"
#   "<root>: unknown: <why the filesystem could not be measured>"
# --verbose adds the healthy line ("<root>: ok: 61% full (...)") so a human or
# an agent can run this directly before fanning work out and see a real number
# rather than silence.
#
# An unmeasurable temp root reports "unknown" rather than passing quietly: a
# check that cannot see the hazard must say so, because silence here is
# indistinguishable from healthy and that is exactly how the incident went
# unnoticed.
#
# Exit status:
#   0  below the warn threshold
#  10  at or above --warn
#  11  at or above --high
#  12  at or above --critical
#   3  the temp root could not be measured (no df, unreadable or missing root,
#      unparseable output). Callers must treat this as unknown, never as healthy
#   1  the arguments were invalid
#
# Environment overrides (the defaults are the operating contract; these exist
# for tests and one-off manual runs, not as a configuration surface):
#   FM_TMP_USAGE_ROOT      temp root to measure (default ${TMPDIR:-/tmp})
#   FM_TMP_USAGE_WARN      warn threshold, percent (default 80)
#   FM_TMP_USAGE_HIGH      high threshold, percent (default 90)
#   FM_TMP_USAGE_CRITICAL  critical threshold, percent (default 95)
set -u

SELF="${BASH_SOURCE[0]}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF" >&2
}

die() {
  printf 'fm-tmp-usage.sh: %s\n' "$1" >&2
  exit 1
}

ROOT_DIR=${FM_TMP_USAGE_ROOT:-${TMPDIR:-/tmp}}
WARN_PCT=${FM_TMP_USAGE_WARN:-80}
HIGH_PCT=${FM_TMP_USAGE_HIGH:-90}
CRITICAL_PCT=${FM_TMP_USAGE_CRITICAL:-95}
VERBOSE=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --root) [ $# -ge 2 ] || die "--root needs a directory"; ROOT_DIR=$2; shift 2 ;;
    --warn) [ $# -ge 2 ] || die "--warn needs a percentage"; WARN_PCT=$2; shift 2 ;;
    --high) [ $# -ge 2 ] || die "--high needs a percentage"; HIGH_PCT=$2; shift 2 ;;
    --critical) [ $# -ge 2 ] || die "--critical needs a percentage"; CRITICAL_PCT=$2; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *) die "unexpected argument: $1" ;;
  esac
done

validate_pct() {  # <value> <flag-name>
  case "$1" in
    ''|*[!0-9]*) die "$2 must be a whole percentage, got '$1'" ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 100 ] || die "$2 must be between 1 and 100, got '$1'"
}

validate_pct "$WARN_PCT" --warn
validate_pct "$HIGH_PCT" --high
validate_pct "$CRITICAL_PCT" --critical
# Ordered thresholds are what makes severity monotonic in fullness: without this
# a misconfigured pair could make a fuller filesystem report a quieter severity.
[ "$WARN_PCT" -le "$HIGH_PCT" ] || die "--warn ($WARN_PCT) must not exceed --high ($HIGH_PCT)"
[ "$HIGH_PCT" -le "$CRITICAL_PCT" ] || die "--high ($HIGH_PCT) must not exceed --critical ($CRITICAL_PCT)"

[ -n "$ROOT_DIR" ] || die "--root must not be empty"

unknown() {  # <reason>
  printf '%s: unknown: %s\n' "$ROOT_DIR" "$1"
  exit 3
}

# Human-readable size from 1024-byte blocks, matching what `df -h` shows an
# operator, so the reported free space can be compared against it directly.
human_size() {  # <blocks-of-1024>
  local kb=$1
  if [ "$kb" -ge 1048576 ]; then
    awk -v k="$kb" 'BEGIN { printf "%.1fG", k / 1048576 }'
  elif [ "$kb" -ge 1024 ]; then
    awk -v k="$kb" 'BEGIN { printf "%.0fM", k / 1024 }'
  else
    printf '%sK' "$kb"
  fi
}

command -v df >/dev/null 2>&1 || unknown "df is not available on this host"
[ -e "$ROOT_DIR" ] || unknown "no such path: $ROOT_DIR"

# -P is the POSIX portable format: exactly one unwrapped line per filesystem, in
# 1024-byte blocks with -k, so the fields stay positional on both Linux and
# macOS even when the device name is long.
if ! df_out=$(df -Pk "$ROOT_DIR" 2>/dev/null) || [ -z "$df_out" ]; then
  unknown "df could not read $ROOT_DIR"
fi

# Take the last data line: a filesystem whose name still wraps on some df would
# leave the numeric fields on that final line.
df_line=$(printf '%s\n' "$df_out" | awk 'NR > 1 && NF >= 5 { last = $0 } END { print last }')
[ -n "$df_line" ] || unknown "df produced no usable line for $ROOT_DIR"

# shellcheck disable=SC2034 # fs/mount are named for readability of the field order.
read -r fs total_kb used_kb avail_kb capacity _rest <<<"$df_line"

case "$total_kb" in ''|*[!0-9]*) unknown "df reported no size for $ROOT_DIR" ;; esac
case "$avail_kb" in ''|*[!0-9]*) avail_kb= ;; esac
case "$used_kb" in ''|*[!0-9]*) used_kb= ;; esac
[ "$total_kb" -gt 0 ] || unknown "df reported a zero-size filesystem for $ROOT_DIR"

# Prefer df's own Capacity field so the number matches what an operator sees in
# `df -h`. Some filesystems report it as "-"; fall back to computing it the same
# way df does, from used against used+available.
pct=${capacity%\%}
case "$pct" in
  ''|*[!0-9]*)
    if [ -n "$used_kb" ] && [ -n "$avail_kb" ] && [ $((used_kb + avail_kb)) -gt 0 ]; then
      pct=$(awk -v u="$used_kb" -v a="$avail_kb" \
        'BEGIN { p = u * 100 / (u + a); r = int(p); if (p > r) r++; print r }')
    else
      unknown "df reported no usable capacity for $ROOT_DIR"
    fi
    ;;
esac
case "$pct" in ''|*[!0-9]*) unknown "df reported an unreadable capacity for $ROOT_DIR" ;; esac

if [ -n "$avail_kb" ]; then
  free_desc="$(human_size "$avail_kb") free of $(human_size "$total_kb")"
else
  free_desc="size $(human_size "$total_kb")"
fi

if [ "$pct" -ge "$CRITICAL_PCT" ]; then
  printf '%s: critical: %s%% full (%s, critical at %s%%)\n' \
    "$ROOT_DIR" "$pct" "$free_desc" "$CRITICAL_PCT"
  exit 12
elif [ "$pct" -ge "$HIGH_PCT" ]; then
  printf '%s: high: %s%% full (%s, high at %s%%)\n' \
    "$ROOT_DIR" "$pct" "$free_desc" "$HIGH_PCT"
  exit 11
elif [ "$pct" -ge "$WARN_PCT" ]; then
  printf '%s: warn: %s%% full (%s, warn at %s%%)\n' \
    "$ROOT_DIR" "$pct" "$free_desc" "$WARN_PCT"
  exit 10
fi

[ "$VERBOSE" -eq 1 ] && printf '%s: ok: %s%% full (%s, warn at %s%%)\n' \
  "$ROOT_DIR" "$pct" "$free_desc" "$WARN_PCT"
exit 0
