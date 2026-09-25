#!/usr/bin/env bash
# Drives real bin/fm-spawn.sh with the REAL installed Pi 0.87.1 answering
# --help/--list-models (real HOME => real credentials/catalog). Only tmux and
# treehouse are stubbed so no actual worker pane is created.
set -u
REPO=$1; shift
REAL_HOME=$HOME
ROOT=$REPO
. "$REPO/tests/fixtures.sh"
TMP_ROOT=$(mktemp -d /tmp/fm-live.XXXX)
drive() { # <label> <harness> <model> [extra...]
  local label=$1 harness=$2 model=$3; shift 3
  local d=$TMP_ROOT/$label home proj wt fakebin
  home=$d/home; proj=$d/project; wt=$d/wt
  fakebin=$(make_spawn_fakebin "$d/fake")
  for t in pi pi-signed; do
    printf '#!/usr/bin/env bash\nHOME=%q exec /opt/homebrew/bin/pi "$@"\n' "$REAL_HOME" > "$fakebin/$t"; chmod +x "$fakebin/$t"
  done
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$label" >/dev/null 2>&1
  fm_test_spawn_brief "$home" "live-$label"
  : > "$d/launch.log"
  echo "=== \$ fm-spawn live-$label <proj> --harness $harness --model '$model' $* --scout"
  out=$(FM_FAKE_LAUNCH_LOG="$d/launch.log" fm_test_run_spawn "$home" "$wt" "$fakebin" "live-$label" "$proj" --harness "$harness" --model "$model" "$@" --scout 2>&1)
  st=$?
  printf '%s\n' "$out" | grep -E 'error|Pi model' | head -5
  echo "exit=$st"
  if [ -s "$d/launch.log" ]; then echo "worker LAUNCHED: $(grep -o -- "--model '[^']*'" "$d/launch.log" | head -1)"; else echo "worker NOT launched"; fi
  [ -e "$home/state/live-$label.meta" ] && echo "meta: $(grep '^model=' "$home/state/live-$label.meta")" || echo "meta: none"
  echo
}
drive sonnet pi sonnet
drive opus1m pi-signed 'claude-opus-5[1m]'
drive bedrock pi amazon-bedrock/us.anthropic.claude-sonnet-5
drive opus pi claude-opus-5
drive sonnetexact pi-signed claude-sonnet-5
drive provid pi anthropic/claude-opus-5-5
drive native pi codex-native/gpt-6-astra --effort ultra
rm -rf "$TMP_ROOT"
