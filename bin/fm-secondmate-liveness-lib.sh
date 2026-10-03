#!/usr/bin/env bash
# shellcheck disable=SC2034 # Probe/relaunch output globals are read by sourcing callers.
# fm-secondmate-liveness-lib.sh - shared persistent-secondmate endpoint liveness
# probing and recovery. bin/fm-bootstrap.sh owns the session-start sweep and
# bin/fm-watch.sh owns the ordinary-supervision poll tick; both drive this
# library so classification handling and the guarded relaunch path stay
# single-sourced here.
#
# A secondmate's recorded endpoint is the tmux window, herdr pane, or remote
# peer it runs in. Probing classifies that endpoint through the owning backend
# adapter's fm_backend_agent_state (local) or the remote control script's
# state verb (remote), which returns one of:
#
#   alive       - a primary-agent runtime is positively running
#   dead        - the endpoint exists, but no agent is running in it
#   missing     - the endpoint itself is gone
#   ambiguous   - backend inventory could not prove either way
#   unreadable  - backend state exists but could not be parsed
#   unverified  - the endpoint is recorded under a session this home does not
#                 own, so probing is not authorized
#
# Only `dead` and `missing` are recovery-authorizing states: they prove the
# agent is not running, so relaunching cannot produce a duplicate endpoint.
# `ambiguous`, `unreadable`, and `unverified` leave the endpoint untouched -
# relaunching on inconclusive evidence could create a second endpoint beside a
# live one - and an unreachable remote host is never evidence of death, so a
# remote route is never replaced by a local endpoint.
#
# Relaunch goes through `bin/fm-spawn.sh <id> --secondmate` with
# FM_SPAWN_NO_GUARD=1, the same guarded path every recovery uses. That path
# re-resolves placement from the task's own metadata and registry route, so a
# remote mate is relaunched on its recorded remote host through bin/fm-on.sh -
# never as a local replacement - behind fm-spawn's own readiness gate and
# per-task spawn lock.
#
# Modes:
#   full - session-start sweep: remote routes run the full readiness repair
#          sequence before probing, and an alive remote route is revalidated
#          (route readable, backend herdr) so the sweep reports drift.
#   poll - watcher tick: remote routes take one read-only state probe per
#          check; repair still happens, but inside fm-spawn's launch gate only
#          when a relaunch is actually authorized.
#
# Concurrency: fm_secondmate_liveness_lock serializes probe+kill+relaunch per
# task across the bootstrap sweep and the watcher tick, so these two drivers
# can never observe or act on the same endpoint at once. It does NOT cover a
# manual `fm-spawn.sh <id> --secondmate` or `bin/fm-secondmate-restart.sh`
# invocation, which never takes this lock; fm_secondmate_liveness_relaunch
# instead probes that launch's own per-task spawn lock
# ($STATE/.spawn-<id>.lock) before acting, and
# fm_sm_live_within_startup_grace gives a just-published endpoint a window
# before `no-agent` is trusted as death at all, so neither path can close an
# endpoint a live spawn just created.
# The attempt ledger (.secondmate-relaunch-<id>, one line per attempt plus one
# per outcome) is both the durable relaunch record and the input to the
# watcher's relaunch bound; teardown removes it.

set -u

FM_SM_LIVE_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Startup grace for a just-launched endpoint, bound to that exact incarnation
# rather than a blanket poll-cadence delay. A fresh Herdr pane's agent
# registers only once the harness itself finishes starting up inside it, so a
# probe landing in that window reads `no-agent` (mapped to `dead` below) for
# reasons that have nothing to do with the agent being gone - acting on it
# kills a launch that was still completing. The bound is read from the
# endpoint's own spawn_gen (bin/fm-spawn.sh's `s<epoch>.<pid>.<random>`
# incarnation marker, refreshed by every fresh spawn AND every relaunch), so an
# endpoint that is actually old is never delayed by it, and a mate that was
# relaunched a minute ago gets its own fresh window rather than inheriting the
# original launch's clock. Default matches FM_SECONDMATE_LIVENESS_TIMEOUT
# (120s): this codebase already treats that as how long a legitimate spawn may
# take, so the grace that precedes recovery eligibility uses the same bound.
FM_SECONDMATE_LIVENESS_STARTUP_GRACE_SECS=${FM_SECONDMATE_LIVENESS_STARTUP_GRACE_SECS:-}
case "$FM_SECONDMATE_LIVENESS_STARTUP_GRACE_SECS" in
  ''|*[!0-9]*) FM_SECONDMATE_LIVENESS_STARTUP_GRACE_SECS=120 ;;
esac

# shellcheck source=bin/fm-backend.sh
. "$FM_SM_LIVE_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-remote-readiness-lib.sh
. "$FM_SM_LIVE_LIB_DIR/fm-remote-readiness-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_SM_LIVE_LIB_DIR/fm-timeout-lib.sh"

# Per-task probe+kill+relaunch serialization. A busy lock means another
# supervisor (the other sweep, or a racing tick) is mid-episode on this mate;
# callers skip and let that episode finish rather than probe a moving target.
# The lock helpers live in bin/fm-wake-lib.sh, which creates the state
# directory when sourced; load it only when a lock is actually taken so that
# sourcing this library stays side-effect free for read-only bootstrap runs.
fm_sm_live_require_locks() {
  command -v fm_lock_try_acquire >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_SM_LIVE_LIB_DIR/fm-wake-lib.sh"
}

fm_secondmate_liveness_lock() {  # <id>
  fm_sm_live_require_locks || return 1
  fm_lock_try_acquire "$STATE/.secondmate-liveness-$1.lock"
}

fm_secondmate_liveness_unlock() {  # <id>
  fm_sm_live_require_locks || return 0
  fm_lock_release "$STATE/.secondmate-liveness-$1.lock" 2>/dev/null || true
}

fm_sm_live_first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

# fm_sm_live_spawn_gen_epoch <meta>: the epoch second embedded in the meta's
# current spawn_gen (bin/fm-spawn.sh's `s<epoch>.<pid>.<random>` incarnation
# marker), or fails (prints nothing) when the field is absent or malformed. A
# persistent remote secondmate's meta carries no spawn_gen at all - it is
# never republished through fm-spawn.sh's local launch path - so this
# correctly fails closed for that shape instead of inventing a timestamp; the
# startup-grace check below treats that failure as "no proof of freshness",
# which preserves today's behavior for remote routes.
fm_sm_live_spawn_gen_epoch() {  # <meta>
  local meta=$1 gen epoch
  gen=$(fm_meta_get "$meta" spawn_gen 2>/dev/null || true)
  case "$gen" in
    s[0-9]*) ;;
    *) return 1 ;;
  esac
  epoch=${gen#s}
  epoch=${epoch%%.*}
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$epoch"
}

# fm_sm_live_within_startup_grace <meta>: true (0) when <meta>'s spawn_gen
# proves its current incarnation is younger than
# FM_SECONDMATE_LIVENESS_STARTUP_GRACE_SECS, with FM_SM_LIVE_GRACE_AGE set to
# the computed age on a true result. A missing or malformed spawn_gen, or a
# recorded epoch in the future (clock skew), proves nothing, so it returns
# false rather than granting an unbounded grace.
fm_sm_live_within_startup_grace() {  # <meta>
  local meta=$1 epoch now
  FM_SM_LIVE_GRACE_AGE=
  epoch=$(fm_sm_live_spawn_gen_epoch "$meta") || return 1
  now=$(date +%s)
  [ "$epoch" -le "$now" ] || return 1
  FM_SM_LIVE_GRACE_AGE=$((now - epoch))
  [ "$FM_SM_LIVE_GRACE_AGE" -lt "$FM_SECONDMATE_LIVENESS_STARTUP_GRACE_SECS" ]
}

# One line per relaunch attempt and one per outcome, keyed by epoch, plus a
# `rearmed` row when a live probe lifts a parked mate. The watcher bound counts
# `attempt` rows inside its window and after the last `rearmed` row; the whole
# file is the durable per-mate relaunch record the captain can count to see
# frequency. Fails when the row cannot be appended.
fm_secondmate_liveness_ledger_add() {  # <id> <attempt|relaunched|failed|rearmed>
  printf '%s\t%s\n' "$(date +%s)" "$2" >> "$STATE/.secondmate-relaunch-$1" 2>/dev/null
}

# Count of attempt rows no older than <window-secs> that follow the last
# `rearmed` row. An absent ledger counts
# zero; an existing ledger that cannot be read fails rather than counting zero.
fm_secondmate_liveness_recent_attempts() {  # <id> <window-secs>
  local id=$1 window=$2 now cutoff ledger
  ledger="$STATE/.secondmate-relaunch-$id"
  if [ ! -e "$ledger" ] && [ ! -L "$ledger" ]; then
    printf '0\n'
    return 0
  fi
  now=$(date +%s)
  cutoff=$((now - window))
  awk -F '\t' -v cutoff="$cutoff" \
    '$2 == "rearmed" { n = 0; next } $1 ~ /^[0-9]+$/ && $1 >= cutoff && $2 == "attempt" { n++ } END { print n + 0 }' \
    "$ledger" 2>/dev/null
}

# fm_secondmate_liveness_probe <meta> <id> <full|poll>
#
# Read-only probe of one registered secondmate's recorded endpoint. Populates:
#
#   FM_SM_LIVE_STATUS  silent | alive | relaunchable | skipped
#   FM_SM_LIVE_STATE   the raw classifier/state word
#   FM_SM_LIVE_KILL    1 when relaunch must first kill a confirmed-dead local
#                      endpoint (its shell husk occupies the name)
#   FM_SM_LIVE_CAUSE   relaunch cause phrase, on relaunchable
#   FM_SM_LIVE_WHERE   backend=<b> or host=<h>, on relaunchable
#   FM_SM_LIVE_REASON  exact skip suffix, on skipped
#   FM_SM_LIVE_LINE    verbose already-live line body, on alive
#
# `silent` means the meta records no endpoint at all - that shape is owned by
# secondmate-provisioning recovery, not liveness.
#
# The caller must hold fm_secondmate_liveness_lock for <id> whenever a
# relaunchable verdict could be acted on.
fm_secondmate_liveness_probe() {  # <meta> <id> <full|poll>
  local meta=$1 id=$2 mode=$3
  FM_SM_LIVE_STATUS=skipped FM_SM_LIVE_STATE=unknown FM_SM_LIVE_KILL=0
  FM_SM_LIVE_CAUSE='' FM_SM_LIVE_WHERE='' FM_SM_LIVE_REASON='' FM_SM_LIVE_LINE=''
  local window harness remote_host remote_rc out agent_state readiness_reason route_out remote_backend
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] || { FM_SM_LIVE_STATUS=silent; return 0; }
  harness=$(fm_meta_get "$meta" harness)
  remote_host=$(fm_meta_get "$meta" remote_host)
  if [ -n "$remote_host" ]; then
    if [ "$mode" = full ]; then
      remote_rc=0
      fm_remote_readiness_ensure "$FM_SM_LIVE_LIB_DIR" "$id" || remote_rc=$?
      if [ "$remote_rc" -eq 255 ]; then
        FM_SM_LIVE_REASON="remote host unavailable or endpoint state unknown; route preserved on $remote_host"
        return 0
      fi
      if [ "$remote_rc" -ne 0 ]; then
        readiness_reason=$(printf '%s\n' "$FM_REMOTE_READINESS_OUT" \
          | awk '/^check [^=]+=(fixable|human):|^action:|^error:/ { print; exit }')
        [ -n "$readiness_reason" ] || readiness_reason=$(fm_sm_live_first_line "$FM_REMOTE_READINESS_OUT")
        [ -n "$readiness_reason" ] || readiness_reason="unknown readiness failure"
        FM_SM_LIVE_REASON="remote readiness failed on $remote_host: $readiness_reason"
        return 0
      fi
    fi
    if out=$("$FM_SM_LIVE_LIB_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh state "$id" < /dev/null 2>/dev/null); then
      remote_rc=0
    else
      remote_rc=$?
    fi
    if [ "$remote_rc" -eq 255 ]; then
      FM_SM_LIVE_REASON="remote host unavailable or endpoint state unknown; route preserved on $remote_host"
      return 0
    fi
    if [ "$remote_rc" -ne 0 ]; then
      FM_SM_LIVE_REASON="remote endpoint probe unreadable on $remote_host"
      return 0
    fi
    agent_state=$(printf '%s\n' "$out" | tail -1)
    FM_SM_LIVE_STATE=$agent_state
    case "$agent_state" in
      alive)
        if [ "$mode" = full ]; then
          if route_out=$("$FM_SM_LIVE_LIB_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh route "$id" < /dev/null 2>/dev/null); then
            remote_rc=0
          else
            remote_rc=$?
          fi
          if [ "$remote_rc" -eq 255 ]; then
            FM_SM_LIVE_REASON="remote host unavailable or endpoint route unknown; route preserved on $remote_host"
            return 0
          fi
          if [ "$remote_rc" -ne 0 ]; then
            FM_SM_LIVE_REASON="alive remote endpoint route is unreadable on $remote_host; inspect and migrate or retire it explicitly"
            return 0
          fi
          remote_backend=$(printf '%s\n' "$route_out" | sed -n 's/^backend=//p' | tail -1)
          if [ "$remote_backend" != herdr ]; then
            FM_SM_LIVE_REASON="alive remote endpoint is recorded on backend '${remote_backend:-missing}'; migrate or retire it explicitly"
            return 0
          fi
        fi
        FM_SM_LIVE_STATUS=alive
        FM_SM_LIVE_LINE="remote secondmate $id already live (host=$remote_host)"
        ;;
      dead|missing)
        if fm_sm_live_within_startup_grace "$meta"; then
          FM_SM_LIVE_REASON="remote endpoint spawned ${FM_SM_LIVE_GRACE_AGE}s ago (host=$remote_host), inside the ${FM_SECONDMATE_LIVENESS_STARTUP_GRACE_SECS}s startup grace; agent may still be registering"
          return 0
        fi
        FM_SM_LIVE_STATUS=relaunchable
        FM_SM_LIVE_CAUSE="remote endpoint $agent_state on its configured host"
        FM_SM_LIVE_WHERE="host=$remote_host"
        ;;
      ambiguous|unreadable|unverified)
        FM_SM_LIVE_REASON="remote endpoint state is $agent_state on $remote_host"
        ;;
      *)
        FM_SM_LIVE_REASON="remote endpoint returned an invalid state"
        ;;
    esac
    return 0
  fi

  local backend target
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target="$window"
  agent_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || agent_state=unreadable
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|omp) ;;
    *)
      case "$agent_state" in dead|missing) agent_state=unverified-harness ;; esac
      ;;
  esac
  FM_SM_LIVE_STATE=$agent_state
  case "$agent_state" in
    alive)
      FM_SM_LIVE_STATUS=alive
      FM_SM_LIVE_LINE="secondmate $id already live (backend=$backend)"
      ;;
    dead|missing)
      if fm_sm_live_within_startup_grace "$meta"; then
        FM_SM_LIVE_REASON="endpoint spawned ${FM_SM_LIVE_GRACE_AGE}s ago (backend=$backend), inside the ${FM_SECONDMATE_LIVENESS_STARTUP_GRACE_SECS}s startup grace; agent may still be registering"
        return 0
      fi
      FM_SM_LIVE_STATUS=relaunchable
      if [ "$agent_state" = dead ]; then
        FM_SM_LIVE_KILL=1
        FM_SM_LIVE_CAUSE="confirmed agent absence on existing endpoint"
      else
        FM_SM_LIVE_CAUSE="recorded endpoint confidently missing"
      fi
      FM_SM_LIVE_WHERE="backend=$backend"
      ;;
    ambiguous)
      FM_SM_LIVE_REASON="existing endpoint has ambiguous agent process (backend=$backend)"
      ;;
    unreadable)
      FM_SM_LIVE_REASON="endpoint probe unreadable (backend=$backend)"
      ;;
    unverified-harness)
      FM_SM_LIVE_REASON="recorded harness '$harness' is unverified for recovery (backend=$backend)"
      ;;
    *)
      FM_SM_LIVE_REASON="agent recovery classifier unverified (backend=$backend)"
      ;;
  esac
  return 0
}

# fm_secondmate_liveness_relaunch <meta> <id> [timeout-secs]
#
# Acts on a `relaunchable` probe verdict for <id>: kills a confirmed-dead local
# endpoint first (FM_SM_LIVE_KILL), records the attempt and its outcome in the
# per-mate ledger, then runs the guarded secondmate spawn. A positive timeout
# wraps the spawn in fm_run_timed so a watcher poll stays bounded; 124/137 mean
# the bound fired. Returns the spawn exit status; combined spawn output is in
# FM_SM_LIVE_OUT and the status in FM_SM_LIVE_RC. When the ledger cannot be
# read or the attempt row cannot be appended, nothing is killed or spawned: the verdict becomes
# FM_SM_LIVE_STATUS=skipped with FM_SM_LIVE_REASON set and this returns 1.
# Caller holds the liveness lock and owns reporting.
#
# Before touching anything, this probes <id>'s own spawn lock
# ($STATE/.spawn-<id>.lock, the same lock bin/fm-spawn.sh holds for its whole
# launch) by acquiring then immediately releasing it. A busy lock means
# another spawn - a concurrent manual launch, or a relaunch already replacing
# this exact endpoint - is live right now, between its own startup-grace
# window and its first meta publish; killing or re-spawning on top of it would
# race that live spawn's own endpoint instead of recovering a dead one, so
# this skips rather than acts. The probe is non-destructive: a clean acquire
# is released at once, so the real spawn this function goes on to run gets to
# take the lock itself.
fm_secondmate_liveness_relaunch() {  # <meta> <id> [timeout-secs]
  local meta=$1 id=$2 timeout=${3:-} spawn_lock
  FM_SM_LIVE_OUT='' FM_SM_LIVE_RC=0
  fm_sm_live_require_locks || {
    FM_SM_LIVE_STATUS=skipped
    FM_SM_LIVE_REASON="lock helpers could not be loaded; endpoint left $FM_SM_LIVE_STATE"
    FM_SM_LIVE_RC=1
    return 1
  }
  spawn_lock="$STATE/.spawn-$id.lock"
  if fm_lock_try_acquire "$spawn_lock"; then
    fm_lock_release "$spawn_lock" || true
  else
    FM_SM_LIVE_STATUS=skipped
    FM_SM_LIVE_REASON="another spawn is already creating task $id; leaving its endpoint alone"
    FM_SM_LIVE_RC=1
    return 1
  fi
  if ! fm_secondmate_liveness_recent_attempts "$id" 0 >/dev/null; then
    FM_SM_LIVE_STATUS=skipped
    FM_SM_LIVE_REASON="relaunch ledger $STATE/.secondmate-relaunch-$id is unreadable; endpoint left $FM_SM_LIVE_STATE"
    FM_SM_LIVE_RC=1
    return 1
  fi
  if ! fm_secondmate_liveness_ledger_add "$id" attempt; then
    FM_SM_LIVE_STATUS=skipped
    FM_SM_LIVE_REASON="relaunch ledger $STATE/.secondmate-relaunch-$id is unwritable; endpoint left $FM_SM_LIVE_STATE"
    FM_SM_LIVE_RC=1
    return 1
  fi
  if [ "$FM_SM_LIVE_KILL" = 1 ]; then
    local backend target window
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    if [ -z "$target" ]; then
      window=$(fm_meta_get "$meta" window)
      target=$window
    fi
    [ -z "$target" ] || fm_backend_kill "$backend" "$target" 2>/dev/null || true
  fi
  local rc=0
  if [ -n "$timeout" ]; then
    FM_SM_LIVE_OUT=$(FM_SPAWN_NO_GUARD=1 fm_run_timed "$timeout" "$FM_ROOT/bin/fm-spawn.sh" "$id" --secondmate 2>&1) || rc=$?
  else
    FM_SM_LIVE_OUT=$(FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "$id" --secondmate 2>&1) || rc=$?
  fi
  FM_SM_LIVE_RC=$rc
  if [ "$rc" -eq 0 ]; then
    fm_secondmate_liveness_ledger_add "$id" relaunched || true
  else
    fm_secondmate_liveness_ledger_add "$id" failed || true
  fi
  return "$rc"
}
