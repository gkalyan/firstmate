#!/usr/bin/env bash
# Drives live-pi-guard.sh from inside a REAL Pi 0.87.1 session's own `!` user
# shell in an isolated Herdr lab session, so the guard runs with whatever
# PI_* parent-session markers a real Pi exports to its nested subprocesses.
set -u
ROOT=${ROOT:?}; D=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"
. "$ROOT/tests/herdr-test-safety.sh"; unset FM_GATE_REFUSE_BYPASS; herdr_forget_inherited_pane
SESSION=$(bin/fm-herdr-lab.sh name piguard) || exit 1; export HERDR_SESSION="$SESSION"
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-piguard.XXXXXX"); W=$(cd "$W" && pwd -P)
trap 'herdr_safe_stop_and_delete "$SESSION" >/dev/null 2>&1; rm -rf "$W"' EXIT
mkdir -p "$W/base" "$W/cwd"; git archive 7cd6e656e51680209176186213e7fce3648ef278 bin | tar -x -C "$W/base"
fm_herdr_lab_prepare "$SESSION" || exit 1
. bin/fm-backend.sh; fm_backend_source herdr; fm_backend_herdr_server_ensure "$SESSION" || exit 1
lab() { fm_herdr_lab_cli "$SESSION" "$@"; }
PANE=$(lab workspace create --label fm-piguard --cwd "$W/cwd" | jq -r '.result.root_pane.pane_id')
lab pane run "$PANE" pi >/dev/null 2>&1
for _ in $(seq 1 100); do [ "$(fm_backend_agent_state herdr "$SESSION:$PANE")" = alive ] && break; sleep 0.3; done
echo "# pi pane state: $(fm_backend_agent_state herdr "$SESSION:$PANE")"
sleep 2
lab pane send-text "$PANE" "!bash $D/live-pi-guard.sh $ROOT $W/base > $W/out.txt 2>&1; echo done >> $W/out.txt" >/dev/null
sleep 0.5; lab pane send-keys "$PANE" Enter >/dev/null
for _ in $(seq 1 120); do grep -q '^done$' "$W/out.txt" 2>/dev/null && break; sleep 0.5; done
cat "$W/out.txt" 2>/dev/null || { echo "no output; pane:"; lab pane read "$PANE" 2>&1 | tail -20; }
