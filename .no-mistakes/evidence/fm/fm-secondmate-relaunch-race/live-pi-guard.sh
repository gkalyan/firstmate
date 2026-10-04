#!/usr/bin/env bash
# Runs bin/fm-spawn.sh's real pi_model_validate (HEAD and BASE copies) against
# the real installed `pi --list-models`, from whatever environment this is
# launched in (the lab drives it from inside a real Pi session's own `!` shell,
# i.e. with the PI_* parent-session markers that session exports).
set -u
ROOT=${1:?root} BASEROOT=${2:?baseroot}
PI=$(command -v pi)
echo "env markers seen: $(env | grep -E '^PI_(CODING_AGENT|MODEL|PROVIDER|SESSION_ID|SESSION_FILE)=' | sed 's/=.*//' | tr '\n' ' ')"
run() {  # <label> <root> <model>
  out=$(bash "$(dirname "$0")/pi-guard-call.sh" "$2" "$PI" "$3" 2>&1); rc=$?
  printf '%-5s model=%-22s rc=%s %s\n' "$1" "$3" "$rc" "$(printf '%s' "$out" | head -c 220)"
}
for m in claude-opus-5 anthropic/claude-opus-5 claude-opus-5-bogus; do
  run HEAD "$ROOT" "$m"; run BASE "$BASEROOT" "$m"
done
echo "-- unreadable catalog (pi stand-in exits 1) must still refuse under HEAD:"
d=$(mktemp -d); printf '#!/bin/sh\nexit 1\n' > "$d/pi"; chmod +x "$d/pi"; PI="$d/pi"; run HEAD "$ROOT" claude-opus-5; rm -rf "$d"
