#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture, yolo flag, and base remote
# from the data/projects.md registry.
# Prints three words to stdout: "<mode> <yolo> <base>" where mode is one of
# no-mistakes|direct-PR|local-only, yolo is on|off, and base is the git remote
# that carries the project's real working line (default "origin").
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init), and
# bin/fm-spawn.sh's advisory registry-deviation notice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                    -> no-mistakes off origin  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)           -> <mode> off origin
#   - <name> [<mode> +yolo] - <desc> (added <date>)     -> <mode> on origin
#   - <name> [<mode> base=<remote>] - <desc> ...        -> <mode> off <remote>
# Tokens inside the bracket group are whitespace-separated and order-independent;
# the first token that is neither "+yolo" nor "base=<remote>" is the mode.
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = when on, firstmate may make routine approval decisions itself.
#   AGENTS.md section 7 is the single owner of authority exceptions, including
#   ask-user contract expansion and stronger captain boundaries.
# base (orthogonal) = the remote a clone's default branch actually tracks, for the
#   project whose "origin" is not its working line (a fork-of-upstream clone whose
#   real base is the fork). bin/fm-fleet-sync.sh syncs and measures against it, so
#   a fork-line clone stops being compared to a remote nobody pushes to.
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
#
# An unknown/missing project, unknown mode, or malformed base falls back to
# "no-mistakes off origin" / "origin" and warns to stderr, so a typo never
# silently drops the gate or redirects a sync to an unusable remote.
# Usage: fm-project-mode.sh [--raw] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# FM_HOME resolution, including the refusal on an ambiently inherited home,
# has one owner: bin/fm-home-anchor-lib.sh.
# shellcheck source=bin/fm-home-anchor-lib.sh
. "$SCRIPT_DIR/fm-home-anchor-lib.sh"
fm_home_anchor_resolve "$FM_ROOT" || exit 1
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
if [ "${1:-}" = "--raw" ]; then
  RAW=1
  shift
fi
NAME=${1:?usage: fm-project-mode.sh [--raw] <project-name>}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  echo "no-mistakes off origin"
  exit 0
fi

# awk emits "<mode> <yolo> <base>" (one line) or nothing if the project is absent.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode=""; yolo="off"; base="origin";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      for (j=1; j<=k; j++) {
        if (a[j] == "+yolo") { yolo="on"; continue }
        if (a[j] ~ /^base=/) { base=substr(a[j], 6); continue }
        if (mode == "") mode = a[j];
      }
    }
    if (mode == "") mode="no-mistakes";
    print mode, yolo, base; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  echo "no-mistakes off origin"
  exit 0
fi

read -r mode yolo base <<EOF
$parsed
EOF
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
# A base remote is passed straight to git, so keep it to a plain remote name: no
# leading dash (which git would read as an option) and no path or shell characters.
case "$base" in
  origin) ;;
  ''|-*|*[!A-Za-z0-9._-]*)
    echo "warn: invalid base remote \"$base\" for $NAME; defaulting to origin" >&2
    base=origin
    ;;
esac
echo "$mode $yolo $base"
