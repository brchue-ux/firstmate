#!/usr/bin/env bash
# Watcher liveness and worktree-tangle guard, called by supervision scripts, by
# fm-wake-drain.sh after it empties queued wakes, and by fm-session-start.sh in
# read-only advisory mode whenever session-lock ownership was not verified.
# First, always warn if the firstmate primary checkout (FM_ROOT) is on a named
# non-default branch, because that means firstmate-on-itself work landed in the
# primary instead of an isolated worktree.
# Second, always warn when the shared temp filesystem is filling up, because a
# full temp root makes this session's own shell fail silently long before
# anything names free space as the cause. bin/fm-tmp-usage.sh owns that
# measurement and its severity; this file owns only the loudness, escalating
# from one line to a re-claimed banner at each higher severity.
# Then, if any task is in flight (a state/<id>.meta exists) and the watcher's
# liveness beacon (state/.last-watcher-beat, touched every poll cycle) is
# missing or older than FM_GUARD_GRACE seconds, prints a loud, clearly delimited
# banner so the agent cannot skim past it in the tool output of whatever it was
# doing - the one channel every harness has.
#
# Repetition is keyed on outage DURATION, not on the episode staying the same. A
# longer outage must get LOUDER: the full banner is re-claimed at every rung of
# the escalation ladder (FM_GUARD_ESCALATE_LADDER, default 5 min / 15 min / 1 h
# since the beacon went stale, then once per FM_GUARD_ESCALATE_REPEAT, default
# hourly), and every line states how long supervision has been down. Between
# rungs, guarded commands print a one-line reminder that carries the same
# duration. Keying suppression on sameness instead would make a ten-second blip
# and a six-hour outage indistinguishable after the first print - exactly
# backwards, since the outage that most needs escalation is the one that gets
# deduplicated hardest.
#
# Episode state lives only under state/.guard-watcher-stale-banner (volatile,
# bounded, one line: episode key, episode start, claimed rung), and the
# temp-pressure episode under state/.guard-tmp-usage-banner (one line: the
# claimed severity rung). Independent alarms (queued wakes, worktree tangle,
# temp pressure) are never suppressed by another alarm's dedup.
# Normal wake handling (watcher briefly down between a wake and the next
# supervision resume) stays inside the grace window and stays silent. Always
# exits 0: the guard warns, it never blocks.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# FM_HOME resolution, including the refusal on an ambiently inherited home,
# has one owner: bin/fm-home-anchor-lib.sh.
# shellcheck source=bin/fm-home-anchor-lib.sh
. "$SCRIPT_DIR/fm-home-anchor-lib.sh"
fm_home_anchor_resolve "$FM_ROOT" || exit 1
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
# Outage-duration rungs, in seconds, at which the full banner is re-claimed.
ESCALATE_LADDER=${FM_GUARD_ESCALATE_LADDER:-300 900 3600}
# Past the last rung, keep re-claiming at this interval so a multi-hour outage
# never falls silent.
ESCALATE_REPEAT=${FM_GUARD_ESCALATE_REPEAT:-3600}
case "$ESCALATE_REPEAT" in ''|*[!0-9]*|0) ESCALATE_REPEAT=3600 ;; esac
queue_pending=false
READ_ONLY=${FM_GUARD_READ_ONLY:-0}
case "$READ_ONLY" in 1|true|TRUE|yes|YES) READ_ONLY=1 ;; *) READ_ONLY=0 ;; esac
CONTINUE_LINE=${FM_GUARD_CONTINUE_LINE:-This is a supervision warning only; the guarded operation WILL still run.}

# Volatile, home-scoped episode marker: one line = the current stale-episode key.
# Cleared when the home leaves the unhealthy state so a later episode re-arms.
STALE_BANNER_MARKER="$STATE/.guard-watcher-stale-banner"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

# Deterministic episode key from beacon state: same continuous stale beacon
# (or continuous absence) shares a key; a recovered-then-restale beacon gets a
# new mtime and therefore a new episode.
fm_guard_stale_episode_key() {
  local state=$1 beat m
  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    printf 'beat:%s\n' "${m:-unknown}"
  else
    printf 'beat:absent\n'
  fi
}

# Read the one-line episode marker. Tolerates the bare-key form written by an
# older firstmate: that records no rung, so the next guarded command escalates
# once and then settles onto the ladder.
fm_guard_marker_read() {
  local state=$1 line field
  FM_GUARD_MARKER_KEY=
  FM_GUARD_MARKER_SINCE=
  FM_GUARD_MARKER_RUNG=0
  line=$(cat "$state/.guard-watcher-stale-banner" 2>/dev/null || true)
  line=${line%%$'\n'*}
  [ -n "$line" ] || return 1
  FM_GUARD_MARKER_KEY=${line%% *}
  case "$line" in
    *' since='*) field=${line#*since=}; FM_GUARD_MARKER_SINCE=${field%% *} ;;
  esac
  case "$line" in
    *' rung='*) field=${line#*rung=}; FM_GUARD_MARKER_RUNG=${field%% *} ;;
  esac
  case "$FM_GUARD_MARKER_SINCE" in ''|*[!0-9]*) FM_GUARD_MARKER_SINCE= ;; esac
  case "$FM_GUARD_MARKER_RUNG" in ''|*[!0-9]*) FM_GUARD_MARKER_RUNG=0 ;; esac
}

# How many escalation rungs an outage of <seconds> has passed. Strictly
# non-decreasing in duration, so a longer outage can only ever be louder.
fm_guard_stale_rung() {
  local dur=$1 rung=0 last=0 threshold
  for threshold in $ESCALATE_LADDER; do
    case "$threshold" in ''|*[!0-9]*) continue ;; esac
    [ "$threshold" -gt "$last" ] && last=$threshold
    [ "$dur" -ge "$threshold" ] && rung=$((rung + 1))
  done
  [ "$dur" -ge "$last" ] && rung=$(( rung + (dur - last) / ESCALATE_REPEAT ))
  printf '%s' "$rung"
}

fm_guard_human_duration() {
  local dur=$1 hours minutes
  if [ "$dur" -lt 60 ]; then
    printf '%ss' "$dur"
  elif [ "$dur" -lt 3600 ]; then
    printf '%sm' "$((dur / 60))"
  else
    hours=$((dur / 3600))
    minutes=$(( (dur % 3600) / 60 ))
    if [ "$minutes" -eq 0 ]; then
      printf '%sh' "$hours"
    else
      printf '%sh %sm' "$hours" "$minutes"
    fi
  fi
}

# Decide, without writing anything, whether this call owns the full banner and
# how long supervision has been down. The beacon's own mtime dates the outage
# exactly; with no beacon at all the honest anchor is when this home first
# noticed, recorded in the marker, and the wording says "at least".
FM_GUARD_EVAL_FULL=0
FM_GUARD_EVAL_RUNG=0
FM_GUARD_EVAL_SINCE=0
FM_GUARD_OUTAGE_DESC=
fm_guard_stale_banner_evaluate() {
  local state=$1 key=$2 now beat mtime dur unanchored=0
  now=$(date +%s)
  beat="$state/.last-watcher-beat"
  fm_guard_marker_read "$state" || true

  FM_GUARD_EVAL_SINCE=
  if [ "$FM_GUARD_MARKER_KEY" = "$key" ]; then
    FM_GUARD_EVAL_SINCE=$FM_GUARD_MARKER_SINCE
    # A matching key that carries no usable start is the older bare-key marker.
    # Without an anchor a beaconless outage would measure itself as zero-length
    # forever and never leave rung 0, so claim once to persist the anchor.
    [ -n "$FM_GUARD_EVAL_SINCE" ] || unanchored=1
  fi
  [ -n "$FM_GUARD_EVAL_SINCE" ] || FM_GUARD_EVAL_SINCE=$now

  mtime=
  if [ -e "$beat" ]; then
    mtime=$(fm_sup_stat_mtime "$beat")
    case "$mtime" in ''|*[!0-9]*) mtime= ;; esac
  fi
  if [ -n "$mtime" ]; then
    dur=$((now - mtime))
    [ "$dur" -ge 0 ] || dur=0
    FM_GUARD_OUTAGE_DESC="down for $(fm_guard_human_duration "$dur")"
  else
    dur=$((now - FM_GUARD_EVAL_SINCE))
    [ "$dur" -ge 0 ] || dur=0
    # With no beacon at all the true start is unknowable, so the wording says
    # "at least"; the accompanying "last beat: never" carries the rest.
    if [ "$dur" -eq 0 ]; then
      FM_GUARD_OUTAGE_DESC='down for an unknown time'
    else
      FM_GUARD_OUTAGE_DESC="down for at least $(fm_guard_human_duration "$dur")"
    fi
  fi

  FM_GUARD_EVAL_RUNG=$(fm_guard_stale_rung "$dur")
  if [ "$FM_GUARD_MARKER_KEY" = "$key" ] && [ "$unanchored" -eq 0 ] \
    && [ "$FM_GUARD_EVAL_RUNG" -le "$FM_GUARD_MARKER_RUNG" ]; then
    FM_GUARD_EVAL_FULL=0
  else
    FM_GUARD_EVAL_FULL=1
  fi
}

# Claim the full banner for this episode AT ITS CURRENT ESCALATION RUNG. Sets
# FM_GUARD_BANNER_FULL=1 when this call owns the announcement and 0 when this
# rung was already announced. A read-only caller decides from recorded state and
# never writes. The shared wake lock helper owns the race-safety mechanics; the
# re-evaluation under the lock makes concurrent claims idempotent.
FM_GUARD_BANNER_FULL=0
fm_guard_claim_stale_banner() {
  local state=$1 key=$2 read_only=$3
  local marker="$state/.guard-watcher-stale-banner"
  local lock="$state/.guard-watcher-stale-banner.lock"
  local i

  if [ "$read_only" -eq 1 ]; then
    fm_guard_stale_banner_evaluate "$state" "$key"
    FM_GUARD_BANNER_FULL=$FM_GUARD_EVAL_FULL
    return 0
  fi

  fm_guard_stale_banner_evaluate "$state" "$key"
  if [ "$FM_GUARD_EVAL_FULL" -eq 0 ]; then
    FM_GUARD_BANNER_FULL=0
    return 0
  fi

  i=0
  while [ "$i" -lt 50 ]; do
    if fm_lock_try_acquire "$lock"; then
      fm_guard_stale_banner_evaluate "$state" "$key"
      if [ "$FM_GUARD_EVAL_FULL" -eq 1 ]; then
        # Bounded write: one line, no growth across episodes (overwrite).
        printf '%s since=%s rung=%s\n' "$key" "$FM_GUARD_EVAL_SINCE" "$FM_GUARD_EVAL_RUNG" > "$marker" || true
      fi
      FM_GUARD_BANNER_FULL=$FM_GUARD_EVAL_FULL
      fm_lock_release "$lock" 2>/dev/null || true
      return 0
    fi
    fm_guard_stale_banner_evaluate "$state" "$key"
    if [ "$FM_GUARD_EVAL_FULL" -eq 0 ]; then
      FM_GUARD_BANNER_FULL=0
      return 0
    fi
    # Brief yield; 0.02s is fine on macOS/Linux sleep, fall back to 1s.
    sleep 0.02 2>/dev/null || sleep 1
    i=$((i + 1))
  done
  # Contended past the spin budget: stay loud rather than dropping the alarm.
  FM_GUARD_BANNER_FULL=1
  return 0
}

fm_guard_clear_stale_banner() {
  rm -f "$STALE_BANNER_MARKER" 2>/dev/null || true
}

# Worktree-tangle alarm, checked FIRST and independent of in-flight tasks: the
# firstmate PRIMARY checkout (FM_ROOT) must stay on its default branch. If a
# crewmate's branch/commits landed here instead of in its own isolated worktree,
# the primary is stranded on a feature branch - surface it loudly on the very next
# fleet action, the same way the watcher-down banner does. Scoped to the primary
# only: detached HEAD (linked worktrees, secondmate homes) never trips this.
tangle_branch=$(fm_primary_tangle_branch "$FM_ROOT" || true)
if [ -n "$tangle_branch" ]; then
  tangle_default=$(fm_default_branch "$FM_ROOT" 2>/dev/null || echo main)
  trule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$trule"
    printf '●  WORKTREE TANGLE - PRIMARY CHECKOUT IS ON A FEATURE BRANCH\n'
    printf "●  %s is on '%s', not its default branch '%s'.\n" "$FM_ROOT" "$tangle_branch" "$tangle_default"
    printf '●  A crewmate likely branched/committed in the primary instead of its own worktree.\n'
    printf "●  The work is SAFE on the '%s' ref.\n" "$tangle_branch"
    if [ "$READ_ONLY" -eq 1 ]; then
      printf '●  This read-only session must leave restore work to a session with verified fleet-lock ownership.\n'
    else
      printf "●  Restore the primary to '%s':\n" "$tangle_default"
      printf '●      git -C %s checkout %s\n' "$FM_ROOT" "$tangle_default"
      printf "●  then re-validate '%s' in a proper isolated worktree.\n" "$tangle_branch"
    fi
    printf '●%s\n' "$trule"
  } >&2
fi

# Shared-temp-filesystem alarm, also independent of in-flight tasks and checked
# before the watcher alarm's early exit: /tmp is typically a small RAM-backed
# filesystem shared by every home on the host, and when it fills, this session's
# own shell starts failing silently with no output - which reads as a broken
# agent rather than a full filesystem. bin/fm-tmp-usage.sh owns the measurement
# and the severity; this owns only how loud each severity is.
#
# Loudness is keyed on SEVERITY, for the same reason the watcher banner keys on
# outage duration: a filesystem that keeps filling must get LOUDER, so each
# higher severity re-claims the full banner and the state that most needs
# attention is never the one deduplicated hardest. Any DROP in severity re-arms
# by lowering the recorded rung to the measured one, not only a full return to
# healthy: after a sweep frees some space the usual path is a partial drop and
# then a refill, and a real re-climb to critical going quiet is exactly the
# failure this check exists to prevent. Occasional re-banners while usage flaps
# around a threshold are the accepted cost of that.
#
# The guard never reclaims anything itself. bin/fm-tmp-sweep.sh is the single
# owner of which scratch is safe to remove, session start already runs it, and
# it deliberately refuses everything that is not recognizably this fleet's own
# orphaned scratch. Deleting on this path would both duplicate that destructive
# predicate on a hot path and risk the consumers that dominated the incident -
# live session scratchpads mid-build - so a human decides about those.
TMP_USAGE_MARKER="$STATE/.guard-tmp-usage-banner"

# Recorded severity rung for the current episode, 0 when none is recorded.
fm_guard_tmp_marker_rung() {
  local recorded
  recorded=$(cat "$TMP_USAGE_MARKER" 2>/dev/null || true)
  recorded=${recorded%%$'\n'*}
  case "$recorded" in ''|*[!0-9]*) recorded=0 ;; esac
  printf '%s' "$recorded"
}

# Record (or clear) the episode's claimed rung. A read-only session never
# writes the marker; it still READS one another session wrote, so it can be
# suppressed to the reminder by an episode it did not claim.
fm_guard_tmp_record_rung() {  # <rung>
  [ "$READ_ONLY" -eq 1 ] && return 0
  if [ "$1" -eq 0 ]; then
    rm -f "$TMP_USAGE_MARKER" 2>/dev/null || true
  else
    # Bounded write: one line, overwritten, never appended across episodes.
    printf '%s\n' "$1" > "$TMP_USAGE_MARKER" 2>/dev/null || true
  fi
  return 0
}

if [ -x "$SCRIPT_DIR/fm-tmp-usage.sh" ]; then
  tmp_line=$("$SCRIPT_DIR/fm-tmp-usage.sh" 2>/dev/null)
  tmp_rc=$?
  # Only the statuses the check documents are a measurement. Every other status
  # - a `die` on bad thresholds, a crash, a signal - is unmeasurable, not
  # healthy: mapping it to rung 0 would print nothing AND drop the episode
  # marker, silently de-escalating an outage in progress. That indistinguishable
  # silence is the exact failure this alarm exists to prevent.
  case "$tmp_rc" in
    0) tmp_rung=0 ;;
    10) tmp_rung=1 ;;
    11) tmp_rung=2 ;;
    12) tmp_rung=3 ;;
    *) tmp_rung=-1 ;;
  esac

  if [ "$tmp_rung" -lt 0 ]; then
    printf 'WARNING: temp filesystem check could not measure the temp root (%s) - treat free space as unknown, not healthy.\n' \
      "${tmp_line:-check exited $tmp_rc with no detail}" >&2
  else
    tmp_claimed=$(fm_guard_tmp_marker_rung)
    if [ "$tmp_rung" -lt "$tmp_claimed" ]; then
      fm_guard_tmp_record_rung "$tmp_rung"
      tmp_claimed=$tmp_rung
    fi

    if [ "$tmp_rung" -eq 0 ]; then
      : # Measured and healthy: silence here means measured, never unchecked.
    elif [ "$tmp_rung" -eq 1 ]; then
      printf 'WARNING: temp filesystem filling up (%s) - reclaim orphaned scratch with bin/fm-tmp-sweep.sh before fanning out heavy work.\n' \
        "$tmp_line" >&2
    elif [ "$tmp_rung" -gt "$tmp_claimed" ]; then
      fm_guard_tmp_record_rung "$tmp_rung"
      urule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
      {
        printf '●%s\n' "$urule"
        if [ "$tmp_rung" -ge 3 ]; then
          printf '●  TEMP FILESYSTEM CRITICALLY FULL - COMMANDS ARE ABOUT TO FAIL SILENTLY\n'
        else
          printf '●  TEMP FILESYSTEM NEARLY FULL\n'
        fi
        printf '●  %s\n' "$tmp_line"
        printf '●  This is the small shared filesystem every home on this host writes scratch into.\n'
        printf '●  When it fills, commands do not error clearly - they return empty failures, which looks like a broken agent.\n'
        if [ "$READ_ONLY" -eq 1 ]; then
          printf '●  This read-only session should report the pressure, not reclaim space.\n'
        else
          printf "●  Reclaim this fleet's own orphaned scratch first:\n"
          printf '●      %s/bin/fm-tmp-sweep.sh\n' "$FM_ROOT"
          printf '●  Whatever that refuses is NOT fleet scratch (live session scratchpads mid-build); a human decides on those - never delete them automatically.\n'
          printf '●  Do not resize the temp filesystem to make this go away; it spends the same RAM the memory ceiling protects.\n'
        fi
        printf '●  %s\n' "$CONTINUE_LINE"
        printf '●%s\n' "$urule"
      } >&2
    else
      printf 'WARNING: temp filesystem still under pressure (%s) - full banner already printed at this severity; it re-prints on any climb above it, including a climb back after the pressure eases.\n' \
        "$tmp_line" >&2
    fi
  fi
fi

# Compute in-flight count and watcher-beacon freshness via the shared
# grace-based predicate (bin/fm-supervision-lib.sh). Only act with tasks in
# flight; count them so the banner can say how much is riding on an absent
# watcher.
fm_supervision_status "$STATE" "$GRACE"
in_flight=$FM_SUP_IN_FLIGHT
watcher_fresh=$FM_SUP_WATCHER_FRESH
beacon_desc=$FM_SUP_BEACON_DESC
if [ "$in_flight" -eq 0 ]; then
  # Leave the unhealthy state (no work riding on the watcher): clear so a later
  # in-flight + stale combination is a fresh episode even if the beacon is still
  # absent with the same key string.
  [ "$READ_ONLY" -eq 1 ] || fm_guard_clear_stale_banner
  exit 0
fi

[ -s "$FM_WAKE_QUEUE" ] && queue_pending=true

# No fresh watcher with tasks in flight is the dangerous state: emit a prominent,
# bordered banner FIRST so it reads as an alarm, not a buried stderr line. Later
# calls in the same episode get a one-line reminder only.
if [ "$watcher_fresh" = false ]; then
  episode_key=$(fm_guard_stale_episode_key "$STATE")
  episode_key=${episode_key%$'\n'}
  fm_guard_claim_stale_banner "$STATE" "$episode_key" "$READ_ONLY"
  print_full_banner=$FM_GUARD_BANNER_FULL
  if [ "$print_full_banner" -eq 1 ]; then
    afk=0
    [ -e "$STATE/.afk" ] && afk=1
    queue_arg=0
    "$queue_pending" && queue_arg=1
    x_mode=0
    [ -f "$CONFIG/x-mode.env" ] && x_mode=1
    fix=$("$SCRIPT_DIR/fm-supervision-instructions.sh" \
      --read-only "$READ_ONLY" \
      --afk "$afk" \
      --x-mode "$x_mode" \
      --queue-pending "$queue_arg" \
      --repair-line 2>/dev/null || printf '%s\n' 'Repair missing watcher supervision according to the session-start operating block.')
    rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    {
      printf '●%s\n' "$rule"
      printf '●  WATCHER DOWN - SUPERVISION IS OFF - %s\n' "$FM_GUARD_OUTAGE_DESC"
      printf '●  %s task(s) in flight, but no watcher has a fresh beacon (last beat: %s, grace %ss).\n' "$in_flight" "$beacon_desc" "$GRACE"
      if [ "$READ_ONLY" -eq 1 ]; then
        printf '●  This read-only session should report the lapse, not repair it.\n'
      else
        printf '●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.\n'
      fi
      printf '●  %s\n' "$CONTINUE_LINE"
      printf '●  %s\n' "$fix"
      printf '●%s\n' "$rule"
    } >&2
  else
    printf 'WARNING: watcher still %s (last beat: %s, grace %ss) - full banner already printed at this escalation level; it re-prints as the outage lengthens.\n' \
      "$FM_GUARD_OUTAGE_DESC" "$beacon_desc" "$GRACE" >&2
  fi
else
  # Healthy again while work is still in flight: end the episode so a later
  # restale re-prints the full banner.
  [ "$READ_ONLY" -eq 1 ] || fm_guard_clear_stale_banner
fi

# Queued wakes are an independent hazard; warn whenever they are pending, even if
# a watcher is alive. Kept after the banner so the no-watcher alarm reads first.
# Dedup of the watcher-down banner never suppresses this warning.
if "$queue_pending"; then
  if [ "$READ_ONLY" -eq 1 ]; then
    echo "WARNING: queued wakes pending - left untouched because this session lacks verified fleet-lock ownership." >&2
  else
    echo "WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else." >&2
  fi
fi
exit 0
