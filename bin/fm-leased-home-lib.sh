#!/usr/bin/env bash
# Shared identity and safety predicates for durably leased secondmate homes.
#
# Firstmate's disposable task worktrees and its persistent secondmate homes are
# allocated from the SAME treehouse pool. What keeps them apart is the durable
# lease bin/fm-home-seed.sh takes with `treehouse get --lease`: treehouse never
# hands a leased worktree to a later plain `treehouse get`, and never prunes it.
#
# That guarantee has exactly one failure mode, and it is not in treehouse:
# `treehouse return` releases a lease for ANY caller unless the caller passes a
# lease precondition (--if-lease-holder / --if-lease-id), and firstmate passes
# none. A teardown pointed at a stale `worktree=` path that has since been leased
# as a home therefore releases that lease, kills the secondmate's processes, and
# drops the home back into the free pool - where the next ordinary
# `treehouse get` legitimately hands it to an unrelated task.
#
# This library is the single owner of the predicates that close that gap:
# identify a path as a secondmate home, and refuse when the caller does not own
# it. Ownership is decided from firstmate's own durable records, never from lease
# state, so a home whose lease has ALREADY been lost is still protected.
#
# Identity comes from two independent sources, either of which is sufficient:
#   - the home's own gitignored .fm-secondmate-home marker, which is
#     self-describing and stays valid when the registry lives in another home;
#   - a `home:` entry in a data/secondmates.md registry.
#
# bin/fm-leased-home-audit.sh reports homes whose lease is already lost.
# This file is sourced and has no side effects on source.

FM_LEASED_HOME_MARKER=".fm-secondmate-home"

# Resolve a path to its physical absolute form, falling back to a lexical
# absolute path when the directory does not exist, so a stale recorded path is
# still comparable against a registry entry.
fm_leased_home_abs() {  # <path>
  local path=$1 resolved
  [ -n "$path" ] || return 1
  if resolved=$(cd "$path" 2>/dev/null && pwd -P); then
    printf '%s\n' "$resolved"
    return 0
  fi
  case "$path" in
    /*) printf '%s\n' "$path" ;;
    *)  printf '%s/%s\n' "$(pwd -P)" "$path" ;;
  esac
}

# Print the secondmate id recorded by a directory's own home marker.
# A symlinked, empty, or syntactically invalid marker is not an identity.
fm_leased_home_marker_id() {  # <dir>
  local dir=$1 marker id
  marker="$dir/$FM_LEASED_HOME_MARKER"
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s\n' "$id"
}

# Print "<id><TAB><home>" for every registered secondmate in a registry file.
# The `(home: <path>;` field is matched anywhere on the line, so a charter
# description carrying its own parentheses cannot hide the home path.
fm_leased_home_registry_entries() {  # <registry>
  local registry=$1
  [ -f "$registry" ] || return 0
  sed -n 's/^- \([A-Za-z0-9._-][A-Za-z0-9._-]*\) .*(home: \([^;)]*\);.*/\1\t\2/p' "$registry"
}

# Identify <path> as a secondmate home. Prints the owning secondmate id and
# returns 0 when it is one; returns 1 when it is not. Any registry files listed
# after the path are consulted after the path's own marker.
fm_leased_home_owner() {  # <path> [registry...]
  local path=$1
  shift
  local abs id registry entry_id entry_home
  abs=$(fm_leased_home_abs "$path") || return 1
  if id=$(fm_leased_home_marker_id "$abs"); then
    printf '%s\n' "$id"
    return 0
  fi
  for registry in "$@"; do
    [ -n "$registry" ] || continue
    while IFS=$'\t' read -r entry_id entry_home; do
      [ -n "$entry_id" ] && [ -n "$entry_home" ] || continue
      entry_home=$(fm_leased_home_abs "$entry_home") || continue
      [ "$entry_home" = "$abs" ] || continue
      printf '%s\n' "$entry_id"
      return 0
    done < <(fm_leased_home_registry_entries "$registry")
  done
  return 1
}

# Refuse when <path> is a secondmate home that <owner_id> does not own.
# An empty <owner_id> owns nothing, which is the correct default: an ordinary
# ship or scout task is never the owner of a persistent home, so every such
# caller is refused. <action> names the operation in the refusal.
fm_leased_home_guard() {  # <path> <owner_id> <action> [registry...]
  local path=$1 owner_id=$2 action=$3
  shift 3
  local id
  id=$(fm_leased_home_owner "$path" "$@") || return 0
  if [ -n "$owner_id" ] && [ "$id" = "$owner_id" ]; then
    return 0
  fi
  echo "REFUSED: $action targets $path, the persistent home of secondmate '$id'." >&2
  echo "That home is leased from the same pool as task worktrees; releasing or reusing it drops the lease and hands the home to the next ordinary task." >&2
  if [ -n "$owner_id" ]; then
    echo "This caller is '$owner_id', not '$id'; a home is retired only through its own secondmate id." >&2
  fi
  echo "Run bin/fm-leased-home-audit.sh to see which homes have already lost their lease." >&2
  return 1
}

# Print the repository a pool worktree was cut from. treehouse keys a pool on the
# BACKING repository's path, so asking a linked worktree about its own pool
# resolves a different (usually empty) one; the backing repo is the only place a
# pool query answers for that worktree. A plain clone is its own backing repo.
fm_leased_home_backing_repo() {  # <dir>
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  printf '%s\n' "$(dirname "$common")"
}

# Print "<status><TAB><lease_holder><TAB><path>" for every worktree in the pool
# that owns <project_dir>. Returns 1 when the pool cannot be read at all, which
# callers must treat as "unknown", never as "no homes at risk".
# An absent lease holder is emitted as a literal "-", never as an empty field:
# tab is IFS whitespace, so `read` collapses consecutive tabs and an empty middle
# field would silently shift the path out of its variable.
fm_leased_home_pool_status() {  # <project-dir>
  local project=$1 out
  command -v treehouse >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  out=$( ( cd "$project" 2>/dev/null && treehouse status --json ) 2>/dev/null ) || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out" \
    | jq -r '.[] | [.status, (if (.lease_holder // "") == "" then "-" else .lease_holder end), .path] | @tsv' 2>/dev/null
}

# Return 0 when <dir> is a linked git worktree rather than a standalone clone.
# Only a linked worktree can have come from a pool, so only it can have a lease
# to lose; a home seeded at an explicit path is an ordinary clone.
fm_leased_home_is_linked_worktree() {  # <dir>
  local dir=$1 git_dir common_dir
  git_dir=$(git -C "$dir" rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 1
  common_dir=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ "$git_dir" != "$common_dir" ]
}

# Print "<status><TAB><lease_holder>" for <home> as recorded by its OWN pool's
# durable state, addressed as <pool-dir>/treehouse-state.json with the pool dir
# two levels above the home.
#
# `treehouse status` only ever reports the pool the backing repo resolves to
# TODAY, so a home in any older pool of the same repo is invisible to it and
# would otherwise be reported as unpooled - a false all-clear for a home that
# really does sit in a recyclable slot. This reads the pool's own records
# instead. Returns 1 when the pool has no record of the home, which means the
# slot is untracked rather than protected.
fm_leased_home_pool_state_record() {  # <home>
  local home=$1 abs pool_dir state
  command -v jq >/dev/null 2>&1 || return 1
  abs=$(fm_leased_home_abs "$home") || return 1
  pool_dir=$(dirname "$(dirname "$abs")")
  state="$pool_dir/treehouse-state.json"
  [ -f "$state" ] || return 1
  jq -er --arg path "$abs" '
    .worktrees[] | select(.path == $path)
    | [(if (.leased // false) then "leased" else "unleased" end),
       (if (.lease_holder // "") == "" then "-" else .lease_holder end)]
    | @tsv
  ' "$state" 2>/dev/null
}

# Print "<id><TAB><home>" for every registered secondmate home that sits in the
# pool owning <project-dir> and is NOT currently leased to that same id - the
# exact condition under which an ordinary `treehouse get` can be handed a home.
# Returns 1 when the pool state could not be read.
fm_leased_home_unprotected() {  # <project-dir> [registry...]
  local project=$1
  shift
  local pool entry_id entry_home status holder path
  pool=$(fm_leased_home_pool_status "$project") || return 1
  local registry
  for registry in "$@"; do
    [ -n "$registry" ] || continue
    while IFS=$'\t' read -r entry_id entry_home; do
      [ -n "$entry_id" ] && [ -n "$entry_home" ] || continue
      entry_home=$(fm_leased_home_abs "$entry_home") || continue
      while IFS=$'\t' read -r status holder path; do
        [ -n "$path" ] || continue
        path=$(fm_leased_home_abs "$path") || continue
        [ "$path" = "$entry_home" ] || continue
        if [ "$status" != leased ] || [ "$holder" != "$entry_id" ]; then
          printf '%s\t%s\n' "$entry_id" "$entry_home"
        fi
      done <<< "$pool"
    done < <(fm_leased_home_registry_entries "$registry")
  done
}
