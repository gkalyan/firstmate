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
# derived. The root's uniqueness comes from the home's own absolute path, not
# its marker id, because an id is unique only inside the registry of the home
# that seeded it - two homes seeded by different parents can carry one id.
# fm_treehouse_project_lock_path folds that same root into the slot-allocation
# lock's identity, so the lock boundary and the pool boundary are derived from
# one fact and homes with disjoint pools never refuse each other's spawns.
#
# These tests pin the pure derivation, the lock identity that follows it, and
# the exact acquire command bin/fm-spawn.sh sends to the pane, so a primary
# home's command and lock stay byte-identical and a secondmate home's carry
# its own root.
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

# derive_lock <home> <project> <user-home>: fm_treehouse_project_lock_path's
# stdout for <project> resolved from <home>; "REFUSED" on any non-zero exit.
derive_lock() {
  local home=$1 project=$2 user_home=$3
  mkdir -p "$user_home"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$user_home" \
    bash -c '. "$1"; fm_treehouse_project_lock_path "$2" || echo REFUSED' _ \
    "$WAKE_LIB" "$project"
}

# make_lock_project <dir> <origin>: a git repo at <dir> whose origin is <origin>.
make_lock_project() {
  local dir=$1 origin=$2
  git init --quiet -b main "$dir"
  git -C "$dir" remote add origin "$origin"
}

# make_child_home <dir> <parent> [id]: a home bound to <parent> by a local
# parent record, carrying a secondmate marker when <id> is given.
make_child_home() {
  local dir=$1 parent=$2 id=${3:-}
  mkdir -p "$dir/state"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$dir/.fm-secondmate-parent"
  [ -z "$id" ] || printf '%s\n' "$id" > "$dir/.fm-secondmate-home"
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
  local home user_home out again
  home="$TMP_ROOT/secondmate-unit"
  user_home="$TMP_ROOT/secondmate-unit-userhome"
  mkdir -p "$home"
  printf 'followforge-sm\n' > "$home/.fm-secondmate-home"
  out=$(derive "$home" "$user_home")
  case "$out" in
    "$user_home/.treehouse-homes/followforge-sm-"*) ;;
    *) fail "a secondmate home derived '$out', expected a \$HOME/.treehouse-homes/followforge-sm-<hash> root" ;;
  esac
  case "$out" in
    */.treehouse-homes/*/*) fail "a secondmate pool root is not a single directory under .treehouse-homes: $out" ;;
  esac
  again=$(derive "$home" "$user_home")
  [ "$again" = "$out" ] \
    || fail "a secondmate home derived two different pool roots across calls: '$out' then '$again'"
  pass "a secondmate home derives one stable pool root carrying its id"
}

# The regression the id-keyed derivation had: bin/fm-home-seed.sh rejects a
# duplicate id only within the seeding home's own registry, so a secondmate of
# the primary and a secondmate of that secondmate can both be called
# 'followforge'. Keyed on the id alone they derived one root, cloned one
# origin, and landed back in a single Treehouse pool - the exact collision this
# change exists to remove.
test_same_id_homes_in_different_subtrees_derive_different_roots() {
  local user_home homeA homeB outA outB
  user_home="$TMP_ROOT/same-id-userhome"
  homeA="$TMP_ROOT/same-id-parent-child"
  homeB="$TMP_ROOT/same-id-parent-child/nested-child"
  mkdir -p "$homeA" "$homeB"
  printf 'followforge\n' > "$homeA/.fm-secondmate-home"
  printf 'followforge\n' > "$homeB/.fm-secondmate-home"
  outA=$(derive "$homeA" "$user_home")
  outB=$(derive "$homeB" "$user_home")
  [ "$outA" != REFUSED ] || fail "secondmate home A derived nothing"
  [ "$outB" != REFUSED ] || fail "secondmate home B derived nothing"
  [ "$outA" != "$outB" ] \
    || fail "two homes sharing the id 'followforge' derived the same pool root: $outA"
  pass "two homes that share a marker id still derive different pool roots"
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

# fm_root_is_secondmate_home's charset guard (bin/fm-primary-scope-lib.sh)
# rejects any id outside [A-Za-z0-9._-], which is what refuses this one: the
# separator, not the dots. A dot-only id such as '..' passes that guard, so
# assert the property the derivation actually has - no id, malformed or not,
# can name a directory other than a fresh one under .treehouse-homes, because
# the home-path hash is always appended.
test_marker_id_outside_the_portable_charset_is_refused() {
  local home out
  home="$TMP_ROOT/malformed-unit"
  mkdir -p "$home"
  printf '../../escaped\n' > "$home/.fm-secondmate-home"
  out=$(derive "$home" "$TMP_ROOT/malformed-unit-userhome")
  [ "$out" = REFUSED ] \
    || fail "a marker id outside the portable charset was accepted into a derived path: $out"
  pass "a marker id outside the portable charset is refused"
}

test_dot_only_marker_id_cannot_collapse_to_the_default_root() {
  local home user_home out resolved
  home="$TMP_ROOT/dot-id-unit"
  user_home="$TMP_ROOT/dot-id-userhome"
  mkdir -p "$home"
  printf '..\n' > "$home/.fm-secondmate-home"
  out=$(derive "$home" "$user_home")
  [ "$out" != REFUSED ] || fail "a dot-only marker id derived nothing at all"
  mkdir -p "$out"
  resolved=$(CDPATH='' cd -- "$out" && pwd -P)
  [ "$resolved" != "$user_home" ] \
    || fail "a marker id of '..' collapsed the pool root back to the shared default root"
  case "$resolved" in
    "$user_home/.treehouse-homes/"*) ;;
    *) fail "a dot-only marker id escaped .treehouse-homes: $resolved" ;;
  esac
  pass "a dot-only marker id cannot collapse the pool root to the default root"
}

# --- the slot-allocation lock that must follow the pool boundary -------------

test_primary_home_lock_path_is_unchanged_by_private_pool_roots() {
  local home user_home project out
  home="$TMP_ROOT/lock-primary"
  user_home="$TMP_ROOT/lock-primary-userhome"
  project="$TMP_ROOT/lock-primary-project"
  mkdir -p "$home/state"
  make_lock_project "$project" 'https://example.invalid/followforge.git'
  out=$(derive_lock "$home" "$project" "$user_home")
  [ "$out" = "$home/state/.treehouse-project-$(printf '%s' 'https://example.invalid/followforge.git' | git hash-object --stdin).lock" ] \
    || fail "a primary home's project lock is no longer keyed on the origin alone: $out"
  pass "a primary home's project lock stays keyed on the origin alone"
}

# The lock's own comment justifies its identity as "every home on this machine
# that can reach the same pool derives the identical path". A home with a
# private pool root reaches no other home's pool, so it must not share the
# lock: without this, the primary and a secondmate spawning for the same origin
# within the same moment hard-refuse each other over disjoint pools.
test_homes_with_disjoint_pool_roots_take_disjoint_project_locks() {
  local root user_home projP projA projB outP outA outB out homeA homeB
  root="$TMP_ROOT/lock-tree"
  user_home="$TMP_ROOT/lock-tree-userhome"
  homeA="$root/child-a"
  homeB="$root/child-a/child-b"
  mkdir -p "$root/state"
  make_child_home "$homeA" "$root" followforge
  make_child_home "$homeB" "$homeA" followforge
  projP="$TMP_ROOT/lock-tree-proj-p"
  projA="$TMP_ROOT/lock-tree-proj-a"
  projB="$TMP_ROOT/lock-tree-proj-b"
  make_lock_project "$projP" 'https://example.invalid/followforge.git'
  make_lock_project "$projA" 'https://example.invalid/followforge.git'
  make_lock_project "$projB" 'https://example.invalid/followforge.git'
  outP=$(derive_lock "$root" "$projP" "$user_home")
  outA=$(derive_lock "$homeA" "$projA" "$user_home")
  outB=$(derive_lock "$homeB" "$projB" "$user_home")
  for out in "$outP" "$outA" "$outB"; do
    [ "$out" != REFUSED ] || fail "a project lock failed to resolve in the home tree"
    case "$out" in "$root/state/"*) ;; *) fail "a project lock left the root home's state dir: $out" ;; esac
  done
  [ "$outP" != "$outA" ] \
    || fail "the primary and a secondmate with a private pool root took the same project lock: $outP"
  [ "$outA" != "$outB" ] \
    || fail "two same-id secondmate homes with disjoint pool roots took the same project lock: $outA"
  pass "homes with disjoint pool roots take disjoint project locks under one anchor"
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
  expected_root="$HOME_DIR/user-home/.treehouse-homes/followforge-sm-$(printf '%s' "$(CDPATH='' cd -- "$HOME_DIR" && pwd -P)" | git hash-object --stdin)"
  line=$(treehouse_acquire_line)
  [ "$line" = "treehouse get --root '$expected_root'" ] \
    || fail "a secondmate home's acquire command did not carry its own pool root: got '$line'"
  pass "a secondmate home's acquire command carries its own distinct --root"
}

# --- the teardown side of the same lock --------------------------------------

# make_forced_retirement_case <name>: a primary home holding one secondmate
# home, that secondmate holding a crewmate task whose worktree is a Treehouse
# pool slot of the secondmate's OWN clone. Echoes
# "<case>|<primary-home>|<mate-home>|<mate-project>|<slot>|<user-home>".
#
# The fake tmux/treehouse stubs only record what teardown reached, so a run
# that gets past the preflight is visible as a recorded `treehouse return`
# rather than as a silently returned slot.
make_forced_retirement_case() {  # <name> <mate-id> <child-id>
  local name=$1 mate_id=$2 child=$3 dir home mate project slot user_home tool
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  mate="$dir/mate"
  user_home="$dir/user-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$dir/fakebin" \
    "$mate/state" "$mate/data" "$mate/config" "$mate/projects" \
    "$dir/pool/1" "$user_home"
  : > "$dir/runtime.log"
  for tool in tmux treehouse; do
    cat > "$dir/fakebin/$tool" <<SH
#!/usr/bin/env bash
printf '$tool' >> "\${FM_RUNTIME_LOG:?}"
printf ' <%s>' "\$@" >> "\${FM_RUNTIME_LOG:?}"
printf '\n' >> "\${FM_RUNTIME_LOG:?}"
exit 0
SH
    chmod +x "$dir/fakebin/$tool"
  done

  git init --quiet -b main "$dir/origin"
  printf 'fixture\n' > "$dir/origin/tracked"
  git -C "$dir/origin" add tracked
  git -C "$dir/origin" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm fixture

  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$home" \
    > "$mate/.fm-secondmate-parent"
  printf '%s\n' "$mate_id" > "$mate/.fm-secondmate-home"
  project="$mate/projects/project"
  git clone -q "$dir/origin" "$project"
  printf '%s\n' \
    "- $mate_id - fixture (home: $mate; scope: test; projects: project; added 2026-01-01)" \
    > "$home/data/secondmates.md"

  # The pool slot is a worktree of the SECONDMATE's clone, which is the shape
  # the private pool root now guarantees and the shape teardown must serialize.
  slot="$dir/pool/1/project"
  git -C "$project" worktree add -q --detach "$slot"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$slot" > "$dir/pool/treehouse-state.json"
  printf 'task=%s\nhome=%s\n' "$child" "$mate" > "$dir/pool/1/.fm-slot-owner"

  fm_write_meta "$home/state/$mate_id.meta" \
    "window=firstmate:fm-$mate_id" "endpoint_task_id=$mate_id" \
    "worktree=$mate" "project=$mate" "home=$mate" \
    "kind=secondmate" "mode=secondmate" "harness=echo" "yolo=off" "projects=project"
  fm_write_meta "$mate/state/$child.meta" \
    "window=firstmate:fm-$child" "endpoint_task_id=$child" \
    "worktree=$slot" "project=$project" "kind=scout"

  printf '%s|%s|%s|%s|%s|%s\n' "$dir" "$home" "$mate" "$project" "$slot" "$user_home"
}

# bin/fm-teardown.sh's preflight_descendant_treehouse_slots takes the slot
# allocation lock for every descendant task before a forced retirement returns
# that task's slot. The lock it must take is the one the task's OWN home
# derives: a secondmate home with a private pool root derives a different lock
# than the home running the teardown, so taking the tearing-down home's lock
# would return a slot out from under a `treehouse get` running in the
# descendant's home at that moment. Assert the refusal, not the derivation:
# with the descendant home's own lock held, the forced retirement must change
# nothing and must never reach `treehouse return`.
test_forced_retirement_locks_the_descendants_own_project_lock() {
  local rec dir home mate project slot user_home mate_id=mate-task child=child-task
  local own_lock teardown_home_lock holder waited=0 rc
  rec=$(make_forced_retirement_case forced-retirement-lock "$mate_id" "$child")
  IFS='|' read -r dir home mate project slot user_home <<EOF
$rec
EOF

  own_lock=$(FM_HOME="$mate" HOME="$user_home" \
    bash -c '. "$1"; fm_treehouse_project_lock_path "$2"' _ "$WAKE_LIB" "$project") \
    || fail "the descendant's own home could not resolve its project lock"
  teardown_home_lock=$(FM_HOME="$home" HOME="$user_home" \
    bash -c '. "$1"; fm_treehouse_project_lock_path "$2"' _ "$WAKE_LIB" "$project") \
    || fail "the tearing-down home could not resolve a project lock"
  [ "$own_lock" != "$teardown_home_lock" ] \
    || fail "this case no longer proves the hazard: both homes derive one lock ($own_lock)"

  # A slot allocation running in the descendant's home right now. Its own
  # process group, because a forced retirement reaps the process tree it finds.
  ( FM_HOME="$mate" HOME="$user_home" exec perl -e 'setpgrp(0, 0); exec @ARGV' \
      bash -c '. "$1"; fm_lock_try_acquire "$2" || exit 1; : > "$3"; exec sleep 60' _ \
      "$WAKE_LIB" "$own_lock" "$dir/lock-held" ) &
  holder=$!
  while [ ! -e "$dir/lock-held" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "$dir/lock-held" ] || fail "the descendant's home never took its own project lock"

  set +e
  FM_HOME="$home" HOME="$user_home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_BLOCK_KILL=1 \
    FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    perl -e 'setpgrp(0, 0); exec @ARGV' "$ROOT/bin/fm-teardown.sh" "$mate_id" --force \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  pkill -P "$holder" >/dev/null 2>&1
  kill "$holder" >/dev/null 2>&1
  wait "$holder" 2>/dev/null
  set -e

  [ "$rc" -ne 0 ] \
    || fail "forced retirement returned a descendant's pool slot while that home held its own allocation lock"
  assert_contains "$(cat "$dir/stderr")" "another Treehouse slot allocation or return is in progress" \
    "the refusal should name the contended slot lock, not some unrelated check"
  assert_contains "$(cat "$dir/stderr")" "$child" \
    "the refusal should name the descendant task whose slot lock was contended"
  assert_present "$mate/state/$child.meta" "the contended forced retirement removed the descendant's record"
  assert_present "$home/state/$mate_id.meta" "the contended forced retirement removed the secondmate's own record"
  assert_present "$slot" "the contended forced retirement touched the descendant's pool slot"
  ! grep -Fq 'treehouse <return>' "$dir/runtime.log" \
    || fail "the contended forced retirement reached treehouse return: $(cat "$dir/runtime.log")"
  pass "a forced retirement serializes on the descendant home's own Treehouse project lock"
}

test_primary_home_derives_no_pool_root
test_secondmate_home_derives_a_root_under_its_own_home
test_two_secondmate_homes_never_derive_the_same_root
test_same_id_homes_in_different_subtrees_derive_different_roots
test_marker_id_outside_the_portable_charset_is_refused
test_dot_only_marker_id_cannot_collapse_to_the_default_root
test_primary_home_lock_path_is_unchanged_by_private_pool_roots
test_homes_with_disjoint_pool_roots_take_disjoint_project_locks
test_forced_retirement_locks_the_descendants_own_project_lock
test_primary_home_spawn_sends_the_unmodified_acquire_command
test_secondmate_home_spawn_sends_its_own_root

echo "# all fm-treehouse-home-pool-root tests passed"
