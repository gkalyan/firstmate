#!/usr/bin/env bash
# Portable regression for bin/fm-spawn.sh's pi_model_validate: the pre-launch
# guard that refuses a Pi or pi-signed launch unless --model matches exactly
# one row, by bare id or exact provider/id, in the selected executable's own
# `--list-models` catalog, which lists only credentialed providers.
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
# needs no installed Pi.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-model-guard)

# A fake pi/pi-signed that answers --help (for the --tui-mode probe) and
# --list-models with a fixed catalog matching the real installed catalog's
# shape (no Bedrock row, because an uncredentialed provider is never listed -
# see the pi harness reference for the empirical check).
#
# Control flags live in FILES under <fakebin>, not environment variables: the
# fix under test (bin/fm-spawn.sh's pi_model_validate) now runs "$bin"
# --list-models through a clean env -i environment, same as every other test
# double here invoked through it, so a control var set only in the test's own
# shell would never reach the fake binary - files survive that sandboxing.
# <fakebin>/.fake-pi-list-status, if present, holds the exit status
# --list-models should return instead of 0 (pins the unreadable-catalog case).
# <fakebin>/.fake-pi-extra-row, if present, holds one more catalog row to
# append. <fakebin>/.fake-pi-refuse-if-session-env, if present, makes
# --list-models refuse when any of the five ambient Pi nested-session markers
# (PI_CODING_AGENT, PI_MODEL, PI_PROVIDER, PI_SESSION_ID, PI_SESSION_FILE) is
# set in ITS OWN environment - the leak the fix must close. $0 is the absolute
# path fm-spawn.sh resolved and invoked, so dirname "$0" reliably finds this
# same fakebin regardless of cwd or PATH.
make_fake_pi() {  # <fakebin> <tool>
  local fakebin=$1 tool=$2
  cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
self_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P) || self_dir=$(dirname "$0")
case "${1:-}" in
--help)
  printf '%s\n' 'Pi 0.87.1' 'Options: --help --tui-mode <mode>'
  ;;
--list-models)
  if [ -e "$self_dir/.fake-pi-list-status" ]; then
    exit "$(cat "$self_dir/.fake-pi-list-status")"
  fi
  if [ -e "$self_dir/.fake-pi-refuse-if-session-env" ]; then
    for name in PI_CODING_AGENT PI_MODEL PI_PROVIDER PI_SESSION_ID PI_SESSION_FILE; do
      eval "val=\${$name:-}"
      [ -z "$val" ] || { echo "fake pi: refusing --list-models: ambient $name leaked into the probe's environment" >&2; exit 9; }
    done
  fi
  printf '%s\n' \
    'provider   model                       context  max-out  thinking  images' \
    'anthropic  claude-opus-5               1M       128K     yes       yes   ' \
    'anthropic  claude-opus-5-5             1M       128K     yes       yes   ' \
    'anthropic  claude-sonnet-5             1M       128K     yes       yes   ' \
    'openai-codex  gpt-5.6-sol              400K     128K     yes       yes   '
  [ ! -e "$self_dir/.fake-pi-extra-row" ] || cat "$self_dir/.fake-pi-extra-row"
  ;;
esac
exit 0
SH
  chmod +x "$fakebin/$tool"
}

# fake_pi_set_list_status <fakebin> <status>: make the next --list-models call
# in this fakebin exit <status> instead of 0.
fake_pi_set_list_status() { printf '%s\n' "$2" > "$1/.fake-pi-list-status"; }

# fake_pi_set_extra_row <fakebin> <row>: append one more catalog row.
fake_pi_set_extra_row() { printf '%s\n' "$2" > "$1/.fake-pi-extra-row"; }

# fake_pi_refuse_if_session_env <fakebin>: make --list-models refuse if it
# sees an ambient PI_* nested-session marker in its own environment.
fake_pi_refuse_if_session_env() { : > "$1/.fake-pi-refuse-if-session-env"; }

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
  assert_contains "$out" "anthropic/claude-sonnet-5" "refusal did not name a satisfying exact provider/id"
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

test_accepts_listed_non_anthropic_provider() {
  local home proj wt fakebin launchlog out id=guard-other-provider
  IFS='|' read -r home proj wt fakebin launchlog < <(make_case other-provider pi "$id")
  out=$(run_scout_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" \
    --harness pi --model openai-codex/gpt-5.6-sol 2>&1)
  expect_code 0 "$?" "a listed non-Anthropic provider/id must be accepted: $out"
  assert_grep "model=openai-codex/gpt-5.6-sol" "$home/state/$id.meta" "meta missing the accepted model"
  assert_contains "$(cat "$launchlog")" "--model 'openai-codex/gpt-5.6-sol'" "accepted model did not reach the launch line"
  pass "fm-spawn: pi_model_validate accepts a listed non-Anthropic provider/id"
}

test_refuses_unlisted_provider_id() {
  local home proj wt fakebin launchlog out id=guard-unlisted-provider
  IFS='|' read -r home proj wt fakebin launchlog < <(make_case unlisted-provider pi "$id")
  out=$(run_scout_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" \
    --harness pi --model amazon-bedrock/us.anthropic.claude-sonnet-5 2>&1)
  expect_code 1 "$?" "an unlisted provider/id must be refused: $out"
  assert_contains "$out" "matches no entry" "refusal did not name the unlisted provider/id as unmatched"
  [ ! -e "$home/state/$id.meta" ] || fail "refused provider still published task metadata"
  [ ! -s "$launchlog" ] || fail "refused provider still launched a worker"
  pass "fm-spawn: pi_model_validate refuses an unlisted provider/id"
}

test_ambiguous_bare_id_suggests_accepted_selector() {
  local home proj wt fakebin launchlog out id
  id=guard-ambiguous
  IFS='|' read -r home proj wt fakebin launchlog < <(make_case ambiguous pi "$id")
  fake_pi_set_extra_row "$fakebin" 'github-copilot  claude-sonnet-5  200K  64K  yes  yes'
  out=$(run_scout_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" --harness pi --model claude-sonnet-5 2>&1)
  expect_code 1 "$?" "a bare id listed by two providers must be refused: $out"
  assert_contains "$out" "matches more than one catalog entry" "refusal did not name the ambiguity"
  assert_contains "$out" "anthropic/claude-sonnet-5" "refusal did not suggest an exact provider/id"
  [ ! -s "$launchlog" ] || fail "ambiguous model still launched a worker"

  id=guard-ambiguous-retry
  IFS='|' read -r home proj wt fakebin launchlog < <(make_case ambiguous-retry pi "$id")
  fake_pi_set_extra_row "$fakebin" 'github-copilot  claude-sonnet-5  200K  64K  yes  yes'
  out=$(run_scout_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" --harness pi --model anthropic/claude-sonnet-5 2>&1)
  expect_code 0 "$?" "retrying with the suggested provider/id must be accepted: $out"
  pass "fm-spawn: pi_model_validate refuses an ambiguous bare id and its suggestion is accepted"
}

test_colliding_selector_is_never_suggested() {
  local home proj wt fakebin launchlog out id
  id=guard-collision
  IFS='|' read -r home proj wt fakebin launchlog < <(make_case collision pi "$id")
  fake_pi_set_extra_row "$fakebin" 'openrouter  anthropic/claude-sonnet-5  200K  64K  yes  yes'
  out=$(run_scout_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" --harness pi --model sonnet 2>&1)
  expect_code 1 "$?" "bare alias 'sonnet' must be refused: $out"
  assert_not_contains "$out" " anthropic/claude-sonnet-5" "refusal offered a selector that is itself ambiguous"
  assert_contains "$out" " anthropic/claude-opus-5" "refusal dropped an unambiguous selector"
  assert_contains "$out" "openrouter/anthropic/claude-sonnet-5" "refusal dropped the unambiguous openrouter selector"

  id=guard-collision-retry
  IFS='|' read -r home proj wt fakebin launchlog < <(make_case collision-retry pi "$id")
  fake_pi_set_extra_row "$fakebin" 'openrouter  anthropic/claude-sonnet-5  200K  64K  yes  yes'
  out=$(run_scout_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" --harness pi --model openrouter/anthropic/claude-sonnet-5 2>&1)
  expect_code 0 "$?" "a suggested unambiguous selector must be accepted: $out"
  pass "fm-spawn: pi_model_validate never suggests a selector that collides with another row's bare id"
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
  fake_pi_set_list_status "$fakebin" 1
  out=$(run_scout_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" \
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
  # catalog guard because it is a separately gated, explicitly typed pathway
  # rather than anything Pi's fuzzy matcher could reach.
  local home proj wt fakebin launchlog out status id=guard-codex-native
  IFS='|' read -r home proj wt fakebin launchlog < <(make_case codex-native pi "$id")
  out=$(run_scout_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" \
    --harness pi --model codex-native/gpt-6-astra --effort ultra 2>&1)
  expect_code 0 "$?" "the gated codex-native/ultra pathway must stay exempt: $out"
  assert_grep "model=codex-native/gpt-6-astra" "$home/state/$id.meta" "meta missing the exempt native model"
  pass "fm-spawn: pi_model_validate exempts the separately-gated codex-native/ultra pathway"
}

# 2026-10-03 incident regression: a secondmate auto-relaunch runs
# bin/fm-spawn.sh as a descendant of the watcher, itself a descendant of the
# captain's own live Pi session, so it inherits that session's own
# PI_CODING_AGENT/PI_MODEL/PI_PROVIDER/PI_SESSION_ID/PI_SESSION_FILE - markers
# Pi sets for ITS OWN nested tool subprocesses, naming the PARENT session's
# model and an already-open session file. A plain interactive invocation never
# carries them. pi_model_validate must read the catalog through a clean env
# (matching fm_worker_account_check's own Pi probe), never whatever ambient
# identity happened to leak down the spawn chain; the fake pi below refuses
# --list-models outright if it sees any of those five variables, so this test
# fails on today's main (which passes the full ambient environment through)
# and passes once the probe runs clean.
test_strips_ambient_pi_session_env_from_the_probe() {
  local home proj wt fakebin launchlog out status id=guard-ambient-env
  IFS='|' read -r home proj wt fakebin launchlog < <(make_case ambient-env pi "$id")
  fake_pi_refuse_if_session_env "$fakebin"
  out=$(PI_CODING_AGENT=true PI_MODEL=claude-sonnet-5 PI_PROVIDER=anthropic \
    PI_SESSION_ID=01a102b3-leaked-parent-session \
    PI_SESSION_FILE=/tmp/leaked-parent-session.jsonl \
    run_scout_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" \
    --harness pi --model claude-opus-5 2>&1)
  status=$?
  expect_code 0 "$status" "a model validated through a leaked parent Pi session's env must still be accepted once the probe runs clean: $out"
  assert_grep "model=claude-opus-5" "$home/state/$id.meta" "meta missing the accepted model"
  pass "fm-spawn: pi_model_validate strips the ambient PI_* session env a nested spawn chain would otherwise leak into the catalog probe"
}

# Companion to the above: the probe must still fail CLOSED (refuse the launch)
# when the catalog genuinely cannot be read, even through the clean env - the
# fix must not weaken that refusal while fixing the leak.
test_unreadable_catalog_still_refuses_under_clean_env() {
  local home proj wt fakebin launchlog out status id=guard-ambient-env-unreadable
  IFS='|' read -r home proj wt fakebin launchlog < <(make_case ambient-env-unreadable pi "$id")
  fake_pi_set_list_status "$fakebin" 1
  out=$(PI_CODING_AGENT=true PI_MODEL=claude-sonnet-5 PI_SESSION_ID=leaked \
    run_scout_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" \
    --harness pi --model claude-opus-5 2>&1)
  status=$?
  expect_code 1 "$status" "a genuinely unreadable catalog must still refuse under the clean-env probe: $out"
  assert_contains "$out" "could not be read" "refusal did not name the unreadable catalog"
  [ ! -e "$home/state/$id.meta" ] || fail "unreadable-catalog refusal still published task metadata"
  pass "fm-spawn: pi_model_validate still refuses an unreadable catalog under the clean-env probe"
}

# 2026-10-03 incident regression, second half: pi_model_validate had no bound
# of its own, so a catalog read that hangs (a contended or slow-starting Pi
# process on the same account root, exactly what a premature auto-relaunch
# produces) silently ate the auto-relaunch's own outer timeout instead of
# failing fast. FM_WORKER_ACCOUNT_CHECK_SECONDS=1 here pins that the probe
# is bounded by that same constant fm_worker_account_check already uses, not
# by the caller's own much longer outer bound.
test_bounds_a_hanging_catalog_read() {
  local home proj wt fakebin out status id=guard-hang start_s end_s elapsed case_dir
  case_dir="$TMP_ROOT/hang"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
--help)
  printf '%s\n' 'Pi 0.87.1' 'Options: --help --tui-mode <mode>'
  ;;
--list-models)
  sleep 30
  printf '%s\n' \
    'provider   model                       context  max-out  thinking  images' \
    'anthropic  claude-opus-5               1M       128K     yes       yes   '
  ;;
esac
exit 0
SH
  chmod +x "$fakebin/pi"
  fm_test_spawn_home "$home" pi
  fm_git_worktree "$proj" "$wt" wt-hang
  fm_test_spawn_brief "$home" "$id"
  : > "$case_dir/launch.log"
  start_s=$(date +%s)
  out=$(FM_WORKER_ACCOUNT_CHECK_SECONDS=1 \
    run_scout_spawn "$home" "$wt" "$fakebin" "$case_dir/launch.log" "$id" "$proj" \
    --harness pi --model claude-opus-5 2>&1)
  status=$?
  end_s=$(date +%s)
  elapsed=$((end_s - start_s))
  expect_code 1 "$status" "a hanging catalog read must refuse rather than launch unvalidated: $out"
  assert_contains "$out" "could not be read" "refusal did not name the unreadable catalog"
  [ "$elapsed" -lt 15 ] || fail "catalog read was not bounded by FM_WORKER_ACCOUNT_CHECK_SECONDS: took ${elapsed}s against a 30s hang"
  pass "fm-spawn: pi_model_validate bounds a hanging catalog read instead of silently eating the outer relaunch timeout"
}

test_refuses_bare_alias_and_claude_code_suffix
test_accepts_listed_non_anthropic_provider
test_refuses_unlisted_provider_id
test_ambiguous_bare_id_suggests_accepted_selector
test_colliding_selector_is_never_suggested
test_accepts_exact_anthropic_ids
test_refuses_unreadable_catalog
test_exempts_codex_native_ultra_pathway
test_strips_ambient_pi_session_env_from_the_probe
test_unreadable_catalog_still_refuses_under_clean_env
test_bounds_a_hanging_catalog_read

echo "# all fm-pi-model-guard tests passed"
