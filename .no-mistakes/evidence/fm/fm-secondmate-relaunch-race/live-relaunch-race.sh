#!/usr/bin/env bash
# Live driver: real Herdr 0.9.0 lab session + real Pi 0.87.1.
# Compares the HEAD liveness lib against the BASE lib (7cd6e65) tick by tick
# while a real Pi pane starts, then exercises the spawn-lock skip and the
# Pi model guard against the real `pi --list-models`.
set -u
ROOT=${ROOT:?}
BASE_SHA=${BASE_SHA:-7cd6e656e51680209176186213e7fce3648ef278}
cd "$ROOT"
. "$ROOT/tests/herdr-test-safety.sh"
unset FM_GATE_REFUSE_BYPASS
herdr_forget_inherited_pane
SESSION=$(bin/fm-herdr-lab.sh name relaunch) || exit 1
export HERDR_SESSION="$SESSION"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
BASE="$LAB/../$(basename "$LAB")-base"; mkdir -p "$BASE"
cleanup() { herdr_safe_stop_and_delete "$SESSION" >/dev/null 2>&1; [ -n "${HOLDER:-}" ] && kill "$HOLDER" 2>/dev/null; rm -rf "$LAB" "$BASE"; }
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null || { echo "lab home create failed"; exit 1; }
git archive "$BASE_SHA" bin | tar -x -C "$BASE"
echo "# session=$SESSION herdr=$(herdr --version) pi=$(pi --version)"
fm_herdr_lab_prepare "$SESSION" || exit 1
. "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr
fm_backend_herdr_server_ensure "$SESSION" || { echo "server ensure failed"; exit 1; }
lab() { fm_herdr_lab_cli "$SESSION" "$@"; }
mkdir -p "$LAB/cwd"

probe() {  # <libroot> <meta> <id>
  FM_HOME="$LAB" STATE="$LAB/state" FM_ROOT="$1" bash -c '
    . "$1/bin/fm-secondmate-liveness-lib.sh"
    fm_secondmate_liveness_probe "$2" "$3" poll
    printf "state=%s status=%s kill=%s cause=%s reason=%s\n" "$FM_SM_LIVE_STATE" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_KILL" "$FM_SM_LIVE_CAUSE" "$FM_SM_LIVE_REASON"
  ' _ "$1" "$2" "$3"
}
write_meta() {  # <id> <target> <spawn_gen>
  { printf 'window=%s\nbackend=herdr\nkind=secondmate\nharness=pi\nhome=%s\n' "$2" "$LAB/sm-$1"
    [ -z "$3" ] || printf 'spawn_gen=%s\n' "$3"; } > "$LAB/state/$1.meta"
}

echo
echo "=== Scenario 1: fresh real Pi pane during startup (HEAD vs BASE probe) ==="
WS=$(lab workspace create --label fm-relaunch-race --cwd "$LAB/cwd") || exit 1
PANE=$(printf '%s' "$WS" | jq -r '.result.root_pane.pane_id')
T="$SESSION:$PANE"
LAUNCH=$(date +%s)
write_meta sm1 "$T" "s$LAUNCH.$$.1"
lab pane run "$PANE" pi >/dev/null 2>&1
saw_base_relaunch=0 saw_head_relaunch=0 saw_head_grace=0
for i in $(seq 1 60); do
  h=$(probe "$ROOT" "$LAB/state/sm1.meta" sm1); b=$(probe "$BASE" "$LAB/state/sm1.meta" sm1)
  printf 't+%02ds HEAD: %s\n      BASE: %s\n' "$(( $(date +%s) - LAUNCH ))" "$h" "$b"
  case "$b" in *status=relaunchable*) saw_base_relaunch=1 ;; esac
  case "$h" in *status=relaunchable*) saw_head_relaunch=1 ;; esac
  case "$h" in *"startup grace"*) saw_head_grace=1 ;; esac
  case "$h" in *state=alive*) break ;; esac
  sleep 0.5
done
echo "summary: base_would_relaunch_fresh_pane=$saw_base_relaunch head_relaunchable=$saw_head_relaunch head_grace_skip=$saw_head_grace"

echo
echo "=== Scenario 2: genuinely old dead endpoint is still recovered ==="
WS2=$(lab workspace create --label fm-relaunch-old --cwd "$LAB/cwd") || exit 1
PANE2=$(printf '%s' "$WS2" | jq -r '.result.root_pane.pane_id'); T2="$SESSION:$PANE2"
sleep 1
write_meta sm2 "$T2" "s$(( $(date +%s) - 3600 )).$$.2"
echo "HEAD old spawn_gen : $(probe "$ROOT" "$LAB/state/sm2.meta" sm2)"
write_meta sm2 "$T2" ""
echo "HEAD no spawn_gen  : $(probe "$ROOT" "$LAB/state/sm2.meta" sm2)"
write_meta sm2 "$T2" "s$(( $(date +%s) + 600 )).$$.2"
echo "HEAD future gen    : $(probe "$ROOT" "$LAB/state/sm2.meta" sm2)"
echo "HEAD grace=0       : $(FM_SECONDMATE_LIVENESS_STARTUP_GRACE_SECS=0; write_meta sm2 "$T2" "s$(date +%s).$$.2"; FM_SECONDMATE_LIVENESS_STARTUP_GRACE_SECS=0 probe "$ROOT" "$LAB/state/sm2.meta" sm2)"
write_meta sm2 "$T2" "s$(( $(date +%s) - 3600 )).$$.2"

echo
echo "=== Scenario 3: relaunch while another spawn holds .spawn-sm2.lock ==="
( STATE="$LAB/state" FM_HOME="$LAB" bash -c '. "$1" && fm_lock_acquire_wait "$2" && sleep 60' _ "$ROOT/bin/fm-wake-lib.sh" "$LAB/state/.spawn-sm2.lock" ) &
HOLDER=$!
for _ in $(seq 1 100); do [ -d "$LAB/state/.spawn-sm2.lock" ] && break; sleep 0.05; done
FM_HOME="$LAB" STATE="$LAB/state" FM_ROOT="$ROOT" bash -c '
  . "$1/bin/fm-secondmate-liveness-lib.sh"
  fm_secondmate_liveness_probe "$2" sm2 poll
  echo "probe: status=$FM_SM_LIVE_STATUS kill=$FM_SM_LIVE_KILL"
  fm_secondmate_liveness_relaunch "$2" sm2 20; rc=$?
  echo "relaunch rc=$rc status=$FM_SM_LIVE_STATUS reason=$FM_SM_LIVE_REASON"
' _ "$ROOT" "$LAB/state/sm2.meta"
echo "pane $PANE2 after skipped relaunch: $(herdr pane get "$PANE2" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.pane_id // "GONE"')"
echo "ledger after skip: $(cat "$LAB/state/.secondmate-relaunch-sm2" 2>/dev/null || echo '<none>')"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; HOLDER=
rm -rf "$LAB/state/.spawn-sm2.lock" 2>/dev/null
echo "-- lock released; relaunch proceeds (kills dead pane, invokes fm-spawn --secondmate):"
FM_HOME="$LAB" STATE="$LAB/state" FM_ROOT="$ROOT" bash -c '
  . "$1/bin/fm-secondmate-liveness-lib.sh"
  fm_secondmate_liveness_probe "$2" sm2 poll
  fm_secondmate_liveness_relaunch "$2" sm2 30; rc=$?
  echo "relaunch rc=$rc status=$FM_SM_LIVE_STATUS spawn-out-first-line: $(printf "%s\n" "$FM_SM_LIVE_OUT" | grep -m1 -i error)"
' _ "$ROOT" "$LAB/state/sm2.meta"
echo "pane $PANE2 after unlocked relaunch: $(herdr pane get "$PANE2" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.pane_id // "GONE"')"
echo "ledger: $(tr '\n' ' ' < "$LAB/state/.secondmate-relaunch-sm2" 2>/dev/null)"
echo "pane $PANE (scenario-1 Pi) still present: $(herdr pane get "$PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.pane_id // "GONE"')"
