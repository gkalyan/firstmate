#!/usr/bin/env bash
# Portable regression for bin/fm-spawn.sh's pi_model_validate: the pre-launch
# guard that refuses a Pi or pi-signed launch unless --model resolves to
# exactly one Anthropic-provider row in the selected executable's own
# `--list-models` catalog.
#
# Why this exists: on 2026-09-25, `--model sonnet` resolved through Pi's own
# alias resolver to Amazon Bedrock's `us.anthropic.claude-sonnet-5`, which had
# no credentials on that machine, so three workers launched straight into
# `Error: No API key found for amazon-bedrock` and sat idle for ~40 minutes
# each while reported as under way. The same day, `--model 'claude-opus-5[1m]'`
# (Claude Code's bracket-suffix syntax) exited immediately with
# `Error: Model "claude-opus-5[1m]" not found`. `bin/fm-spawn.sh` launched
# both without objection.
#
# This suite pins the guard's LOGIC with a fake pi/pi-signed binary so CI
# needs no installed Pi; tests/fm-pi-model-guard-live-e2e.test.sh is the
# default-on live guard that proves the same refusal against the REAL
# installed Pi catalog on this machine, per firstmate-coding-guidelines'
# harness-dependent-check rule.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-model-guard)

# A fake pi/pi-signed that answers --help (for the --tui-mode probe) and
# --list-models with a fixed Anthropic-only catalog matching the real
# installed catalog's shape on 2026-09-25 and today (no Bedrock row, because
# this machine's pi has no Bedrock credentials - see the pi harness reference
# for the empirical check). --list-models exits nonzero when
# FM_FAKE_PI_LIST_STATUS is set, to pin the unreadable-catalog case.
make_fake_pi() {  # <fakebin> <tool>
  local fakebin=$1 tool=$2
  cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
--help)
  printf '%s\n' 'Pi 0.87.1' 'Options: --help --tui-mode <mode>'
  ;;
--list-models)
  [ "${FM_FAKE_PI_LIST_STATUS:-0}" -eq 0 ] || exit "${FM_FAKE_PI_LIST_STATUS}"
  printf '%s\n' \
    'provider   model                       context  max-out  thinking  images' \
    'anthropic  claude-opus-5               1M       128K     yes       yes   ' \
    'anthropic  claude-opus-5-5             1M       128K     yes       yes   ' \
    'anthropic  claude-sonnet-5             1M       128K     yes       yes   '
  ;;
esac
exit 0
SH
  chmod +x "$fakebin/$tool"
}

make_case() {  # <name> <harness> <id> -> echoes home|proj|wt|fakebin|launchlog
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  make_fake_pi "$fakebin" pi
  make_fake_pi "$fakebin" pi-signed
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  : > "$case_dir/launch.log"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$case_dir/launch.log"
}

run_scout_spawn() {  # <home> <wt> <fakebin> <launchlog> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --scout
}

test_refuses_bare_alias_and_claude_code_suffix() {
  local home proj wt fakebin launchlog out status id

  id=guard-sonnet
  IFS='|' read -r home proj wt fakebin launchlog < <(make_case sonnet pi "$id")
  out=$(run_scout_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" --harness pi --model sonnet 2>&1)
  status=$?
  expect_code 1 "$status" "bare alias 'sonnet' must be refused: $out"
  assert_contains "$out" "Pi model 'sonnet' matches no entry" "refusal did not name the alias as unmatched"
  assert_contains "$out" "claude-sonnet-5" "refusal did not name a satisfying Anthropic id"
  [ ! -e "$home/state/$id.meta" ] || fail "refused alias still published task metadata"
  [ ! -s "$launchlog" ] || fail "refused alias still launched a worker"

  id=guard-suffix
  IFS='|' read -r home proj wt fakebin launchlog < <(make_case suffix pi-signed "$id")
  out=$(run_scout_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" --harness pi-signed --model 'claude-opus-5[1m]' 2>&1)
  status=$?
  expect_code 1 "$status" "Claude Code's [1m] suffix syntax must be refused on Pi: $out"
  assert_contains "$out" "Pi model 'claude-opus-5[1m]' matches no entry" "refusal did not name the bracketed model as unmatched"
  [ ! -e "$home/state/$id.meta" ] || fail "refused suffix model still published task metadata"

  pass "fm-spawn: pi_model_validate refuses a bare alias and a Claude Code model suffix"
}

test_refuses_other_provider() {
  local home proj wt fakebin launchlog out status id=guard-other-provider
  IFS='|' read -r home proj wt fakebin launchlog < <(make_case other-provider pi "$id")
  out=$(run_scout_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" \
    --harness pi --model amazon-bedrock/us.anthropic.claude-sonnet-5 2>&1)
  expect_code 1 "$?" "an explicit non-Anthropic provider/id must be refused: $out"
  assert_contains "$out" "matches no entry" "refusal did not name the unlisted provider/id as unmatched"
  [ ! -e "$home/state/$id.meta" ] || fail "refused provider still published task metadata"
  pass "fm-spawn: pi_model_validate refuses an explicit match on a non-Anthropic provider"
}

test_accepts_exact_anthropic_ids() {
  local home proj wt fakebin launchlog out status id

  id=guard-opus
  IFS='|' read -r home proj wt fakebin launchlog < <(make_case opus pi "$id")
  out=$(run_scout_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" --harness pi --model claude-opus-5 2>&1)
  status=$?
  expect_code 0 "$status" "claude-opus-5 should be accepted: $out"
  assert_grep "model=claude-opus-5" "$home/state/$id.meta" "meta missing the accepted model"
  assert_contains "$(cat "$launchlog")" "--model 'claude-opus-5'" "accepted model did not reach the launch line"

  id=guard-sonnet-exact
  IFS='|' read -r home proj wt fakebin launchlog < <(make_case sonnet-exact pi-signed "$id")
  out=$(run_scout_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" --harness pi-signed --model claude-sonnet-5 2>&1)
  status=$?
  expect_code 0 "$status" "claude-sonnet-5 should be accepted: $out"
  assert_grep "model=claude-sonnet-5" "$home/state/$id.meta" "meta missing the accepted model"

  pass "fm-spawn: pi_model_validate accepts the exact historical Anthropic ids"
}

test_refuses_unreadable_catalog() {
  local home proj wt fakebin launchlog out status id=guard-unreadable
  IFS='|' read -r home proj wt fakebin launchlog < <(make_case unreadable pi "$id")
  out=$(FM_FAKE_PI_LIST_STATUS=1 run_scout_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" \
    --harness pi --model claude-opus-5 2>&1)
  expect_code 1 "$?" "an unreadable Pi catalog must refuse rather than launch unvalidated: $out"
  assert_contains "$out" "could not be read" "refusal did not name the unreadable catalog"
  [ ! -e "$home/state/$id.meta" ] || fail "unreadable-catalog refusal still published task metadata"
  [ ! -s "$launchlog" ] || fail "unreadable-catalog refusal still launched a worker"
  pass "fm-spawn: pi_model_validate refuses rather than launching when the catalog cannot be read"
}

test_exempts_codex_native_ultra_pathway() {
  # codex-native/<id> is the installed pi-codex-native extension's own
  # runtime-registered provider (bin/fm-harness.sh's validate_native_effort),
  # never a row Pi's own --list-models can print. It is out of scope for the
  # Anthropic-provider guard because it is a separately gated, explicitly
  # typed pathway rather than anything Pi's alias resolver could reach.
  local home proj wt fakebin launchlog out status id=guard-codex-native
  IFS='|' read -r home proj wt fakebin launchlog < <(make_case codex-native pi "$id")
  out=$(run_scout_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" \
    --harness pi --model codex-native/gpt-6-astra --effort ultra 2>&1)
  expect_code 0 "$?" "the gated codex-native/ultra pathway must stay exempt: $out"
  assert_grep "model=codex-native/gpt-6-astra" "$home/state/$id.meta" "meta missing the exempt native model"
  pass "fm-spawn: pi_model_validate exempts the separately-gated codex-native/ultra pathway"
}

test_refuses_bare_alias_and_claude_code_suffix
test_refuses_other_provider
test_accepts_exact_anthropic_ids
test_refuses_unreadable_catalog
test_exempts_codex_native_ultra_pathway

echo "# all fm-pi-model-guard tests passed"
