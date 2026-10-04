#!/usr/bin/env bash
# pi-guard-call.sh <root> <pi-bin> <model>: load bin/fm-spawn.sh's own
# pi_model_validate from <root> (with its timeout/account libs) and call it.
set -u
. "$1/bin/fm-timeout-lib.sh"
. "$1/bin/fm-worker-account-lib.sh" 2>/dev/null || true
: "${FM_WORKER_ACCOUNT_CHECK_SECONDS:=30}"
eval "$(awk '/^pi_model_validate\(\) /{f=1} f{print} f&&/^}/{exit}' "$1/bin/fm-spawn.sh")"
pi_model_validate "$2" "$3"
