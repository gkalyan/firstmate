#!/usr/bin/env bash
# Regression tests for the Treehouse pool-root collision fix.
#
# Two homes that each clone the same project into a same-named local directory
# (the ordinary case) used to resolve to Treehouse's one shared default pool,
# so whichever home's clone reached it first owned every slot and a spawn from
# the other home was handed a worktree of a project it did not own. Claude's
# workspace-trust pre-registration (bin/fm-claude-trust.sh) correctly refused
# to launch into that worktree rather than wedging, but the underlying home
# still could not spawn anything for that project at all.
#
# bin/fm-wake-lib.sh's fm_treehouse_home_pool_root derives a Treehouse pool
# root private to a secondmate home and nothing for any other home, and
# bin/fm-spawn.sh passes that root to `treehouse get` only when one is
# derived. These tests pin the pure derivation and the exact acquire command
# bin/fm-spawn.sh sends to the pane, so a primary home's command stays
# byte-identical and a secondmate home's carries its own --root.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-treehouse-home-pool-root)

WAKE_LIB="$ROOT/bin/fm-wake-lib.sh"

# derive <home> <user-home>: fm_treehouse_home_pool_root's stdout for <home>,
# with $HOME pinned to <user-home>; "REFUSED" on any non-zero exit so a case
# can assert either shape without caring about exit codes directly.
derive() {
  local home=$1 user_home=$2
  mkdir -p "$user_home"
  FM_ROOT_OVERRIDE='' FM_HOME="$TMP_ROOT/unrelated-home" HOME="$user_home" \
    bash -c '. "$1"; fm_treehouse_home_pool_root "$2" || echo REFUSED' _ \
    "$WAKE_LIB" "$home"
}

# --- pure derivation ---------------------------------------------------------

test_primary_home_derives_no_pool_root() {
  local home out
  home="$TMP_ROOT/primary-unit"
  mkdir -p "$home"
  out=$(derive "$home" "$TMP_ROOT/primary-unit-userhome")
  [ "$out" = REFUSED ] \
    || fail "a plain home with no .fm-secondmate-home marker unexpectedly derived a pool root: $out"
  pass "a primary home derives no Treehouse pool root"
}

test_secondmate_home_derives_a_root_under_its_own_home() {
  local home user_home out expected
  home="$TMP_ROOT/secondmate-unit"
  user_home="$TMP_ROOT/secondmate-unit-userhome"
  mkdir -p "$home"
  printf 'followforge-sm\n' > "$home/.fm-secondmate-home"
  out=$(derive "$home" "$user_home")
  expected="$user_home/.treehouse-homes/followforge-sm"
  [ "$out" = "$expected" ] \
    || fail "a secondmate home derived '$out', expected '$expected'"
  pass "a secondmate home derives a pool root private to its own id"
}

test_two_secondmate_homes_never_derive_the_same_root() {
  local user_home homeA homeB outA outB
  user_home="$TMP_ROOT/two-sm-userhome"
  homeA="$TMP_ROOT/two-sm-a"
  homeB="$TMP_ROOT/two-sm-b"
  mkdir -p "$homeA" "$homeB"
  printf 'sm-alpha\n' > "$homeA/.fm-secondmate-home"
  printf 'sm-beta\n' > "$homeB/.fm-secondmate-home"
  outA=$(derive "$homeA" "$user_home")
  outB=$(derive "$homeB" "$user_home")
  [ -n "$outA" ] && [ "$outA" != REFUSED ] || fail "secondmate home A derived nothing: $outA"
  [ -n "$outB" ] && [ "$outB" != REFUSED ] || fail "secondmate home B derived nothing: $outB"
  [ "$outA" != "$outB" ] || fail "two distinct secondmate homes derived the same pool root: $outA"
  pass "two secondmate homes on the same machine never derive the same pool root"
}

test_malformed_marker_id_is_refused_not_used_as_a_path() {
  local home out
  home="$TMP_ROOT/malformed-unit"
  mkdir -p "$home"
  printf '../../escaped\n' > "$home/.fm-secondmate-home"
  out=$(derive "$home" "$TMP_ROOT/malformed-unit-userhome")
  [ "$out" = REFUSED ] \
    || fail "a marker id with path-traversal characters was accepted into a derived path: $out"
  pass "a malformed marker id is refused rather than folded into a derived path"
}

# --- what bin/fm-spawn.sh actually sends to the pane -------------------------

# make_case <name> <id>: a project plus a pre-acquired linked worktree
# standing in for what `treehouse get` would hand back (the fake tmux reports
# this path as the pane's cwd, so fm-spawn.sh's isolation poll adopts it on
# its first read; see tests/fixtures.sh fm_test_fake_tmux_spawn). Echoes
# "<case>|<home>|<project>|<pool>|<fakebin>".
make_case() {
  local name=$1 id=$2 case_dir home project pool fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  pool="$case_dir/pool"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  patch_fakebin_tmux_for_acquire_capture "$fakebin"

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm initial
  git -C "$project" worktree add --quiet --detach "$pool" HEAD

  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$project" "$pool" "$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# fm-spawn.sh acquires the pool worktree through spawn_send_text_line, which
# submits the whole command as one non-literal `tmux send-keys -t <target>
# "<text>" Enter` (bin/backends/tmux.sh), never through the `-l` literal path
# tests/fixtures.sh's shared fake tmux was built to log (that path is what the
# launch command itself uses). Overwrite just this case's tmux stub with one
# that also logs that non-literal text argument, so the acquire command is
# observable without changing the shared fixture every other suite relies on.
patch_fakebin_tmux_for_acquire_capture() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    shift
    prev=
    for a in "$@"; do
      if [ "$prev" = -l ] && [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
        printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
      elif [ "$prev" = -t ] || [ "$prev" = -l ] || [ "$a" = -t ] || [ "$a" = -l ] || [ "$a" = Enter ]; then
        :
      elif [ -n "${FM_FAKE_ACQUIRE_LOG:-}" ]; then
        printf '%s\n' "$a" >> "$FM_FAKE_ACQUIRE_LOG"
      fi
      prev=$a
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

run_spawn() {  # <id> [fm-spawn args...]
  local id=$1
  shift
  FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_FAKE_ACQUIRE_LOG="$CASE_DIR/acquire.log" \
    fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" "$@"
}

# The acquire command bin/fm-spawn.sh sent to the pane, or empty if none was.
treehouse_acquire_line() {
  head -1 "$CASE_DIR/acquire.log" 2>/dev/null
}

test_primary_home_spawn_sends_the_unmodified_acquire_command() {
  local rec id out status line
  id='pool-root-primary-r1'
  rec=$(make_case primary-e2e "$id")
  read_case "$rec"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a primary-home scout spawn should launch"$'\n'"$out"

  line=$(treehouse_acquire_line)
  [ "$line" = 'treehouse get' ] \
    || fail "a primary home's acquire command is no longer the plain 'treehouse get': got '$line'"
  pass "a primary home sends the exact unmodified 'treehouse get' acquire command"
}

test_secondmate_home_spawn_sends_its_own_root() {
  local rec id out status line expected_root
  id='pool-root-secondmate-r1'
  rec=$(make_case secondmate-e2e "$id")
  read_case "$rec"
  printf 'followforge-sm\n' > "$HOME_DIR/.fm-secondmate-home"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a secondmate-home scout spawn should launch"$'\n'"$out"

  # fm_test_run_spawn always runs the launch with HOME=<home>/user-home
  # (tests/fixtures.sh), so that is the base the fix derives the root under.
  expected_root="$HOME_DIR/user-home/.treehouse-homes/followforge-sm"
  line=$(treehouse_acquire_line)
  [ "$line" = "treehouse get --root '$expected_root'" ] \
    || fail "a secondmate home's acquire command did not carry its own pool root: got '$line'"
  pass "a secondmate home's acquire command carries its own distinct --root"
}

test_primary_home_derives_no_pool_root
test_secondmate_home_derives_a_root_under_its_own_home
test_two_secondmate_homes_never_derive_the_same_root
test_malformed_marker_id_is_refused_not_used_as_a_path
test_primary_home_spawn_sends_the_unmodified_acquire_command
test_secondmate_home_spawn_sends_its_own_root

echo "# all fm-treehouse-home-pool-root tests passed"
