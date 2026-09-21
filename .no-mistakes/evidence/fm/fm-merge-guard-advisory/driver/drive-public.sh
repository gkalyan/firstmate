#!/usr/bin/env bash
# Live read-only driver: runs bin/fm-pr-merge.sh against a PUBLIC GitHub pull
# request with EVERY forge read proxied to the operator's real gh. Only
# `gh pr merge` is intercepted: it never runs, it is recorded and refused, so
# the run cannot write to the public repository.
set -u
ROOT=${FM_DRIVE_ROOT:?}
SCRIPT=${FM_DRIVE_SCRIPT:-$ROOT/bin/fm-pr-merge.sh}
REAL_GH=$(command -v gh)
case_name=$1; shift
url=$1; shift
case_dir=/tmp/fmdrive/public/$case_name
rm -rf "$case_dir"
mkdir -p "$case_dir/state" "$case_dir/home/data" "$case_dir/fakebin" "$case_dir/wt" "$case_dir/user-home"
cp "$ROOT/.tasks.toml" "$case_dir/home/.tasks.toml"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$case_dir/home/data/backlog.md"
{ printf 'window=fm-task-x1\n'; printf 'worktree=%s/wt\n' "$case_dir"; printf 'project=%s/project\n' "$case_dir";
  printf 'kind=ship\nmode=no-mistakes\n'; } > "$case_dir/state/task-x1.meta"
: > "$case_dir/gh.log"

cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/gh.log"
case "\${1:-} \${2:-}" in
  "pr merge")
    printf 'DRIVER REFUSED: this live run is read-only, no merge was attempted\n' >&2
    exit 1 ;;
esac
exec "$REAL_GH" "\$@"
SH
cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$case_dir/fakebin/gh" "$case_dir/fakebin/gh-axi"

FM_ROOT_OVERRIDE="$ROOT" \
FM_HOME="$case_dir/home" \
FM_STATE_OVERRIDE="$case_dir/state" \
FM_GATE_REFUSE_BYPASS=1 \
PATH="$case_dir/fakebin:$PATH" \
  "$SCRIPT" task-x1 "$url" "$@" > "$case_dir/stdout" 2> "$case_dir/stderr"
rc=$?
echo "--- exit: $rc"
echo "--- stderr:"; cat "$case_dir/stderr"
echo "--- gh calls (live, proxied to real gh):"; cut -c1-100 "$case_dir/gh.log"
exit "$rc"
