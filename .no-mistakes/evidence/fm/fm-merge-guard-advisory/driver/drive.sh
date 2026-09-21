#!/usr/bin/env bash
# Standalone driver: runs bin/fm-pr-merge.sh the way an operator does, against a
# gh stub that reproduces real gh flag semantics (-f raw string, -F typed JSON
# scalar) and real GraphQL String!/Int! variable validation.
set -u
ROOT=${FM_DRIVE_ROOT:?}
SCRIPT=${FM_DRIVE_SCRIPT:-$ROOT/bin/fm-pr-merge.sh}
case_name=$1; shift
url=$1; shift
case_dir=/tmp/fmdrive/cases/$case_name
rm -rf "$case_dir"
mkdir -p "$case_dir/state" "$case_dir/home/data" "$case_dir/home/config" "$case_dir/fakebin" "$case_dir/wt" "$case_dir/user-home"
cp "$ROOT/.tasks.toml" "$case_dir/home/.tasks.toml"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$case_dir/home/data/backlog.md"
{ printf 'window=fm-task-x1\n'; printf 'worktree=%s/wt\n' "$case_dir"; printf 'project=%s/project\n' "$case_dir";
  printf 'kind=ship\nmode=no-mistakes\n'; } > "$case_dir/state/task-x1.meta"
printf 'state=MERGED\nmerged=true\nqueued=false\nbase=main\n' > "$case_dir/github-outcome"
: > "$case_dir/github-rules"
: > "$case_dir/gh.log"
cp "$FM_DRIVE_VIEW" "$case_dir/github-view.json"
python3 - "$case_dir/github-view.json" "$case_dir/github-head" <<'PY'
import json,sys
v=json.load(open(sys.argv[1]))
open(sys.argv[2],'w').write(v["headRefOid"]+"\n")
PY
if [ -n "${FM_DRIVE_REQUIRED:-}" ]; then cp "$FM_DRIVE_REQUIRED" "$case_dir/github-required.json"; fi

cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *statusCheckRollup*) cat "$FM_TEST_GH_VIEW_JSON"; exit 0 ;;
      *headRefOid*) cat "$FM_TEST_GH_HEAD"; exit 0 ;;
    esac ;;
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}"; exit 0 ;;
  "api graphql")
    # Reproduce gh's own flag handling: -f sends a raw string, -F parses the
    # value as a JSON scalar when it looks like one. Then validate the variables
    # against the query's declared types the way the GraphQL server does.
    query=''; jqprog=''; vars='{}'; want=''
    for arg in "$@"; do
      case "$want" in
        f) key=${arg%%=*}; val=${arg#*=}
           if [ "$key" = query ]; then query=$val
           else vars=$(jq -c --arg k "$key" --arg v "$val" '.[$k]=$v' <<<"$vars"); fi
           want=''; continue ;;
        F) key=${arg%%=*}; val=${arg#*=}
           if printf '%s' "$val" | grep -Eq '^(-?[0-9]+(\.[0-9]+)?|true|false|null)$'; then
             vars=$(jq -c --arg k "$key" --argjson v "$val" '.[$k]=$v' <<<"$vars")
           else
             vars=$(jq -c --arg k "$key" --arg v "$val" '.[$k]=$v' <<<"$vars")
           fi
           want=''; continue ;;
        jq) jqprog=$arg; want=''; continue ;;
      esac
      case "$arg" in
        -f|--raw-field) want=f ;;
        -F|--field) want=F ;;
        --jq) want=jq ;;
      esac
    done
    # GraphQL variable coercion: String! rejects a non-string, Int! rejects a
    # non-integer. This is what real GitHub answers, and gh exits nonzero on it.
    while IFS= read -r decl; do
      name=${decl%%:*}; type=${decl#*:}
      actual=$(jq -r --arg k "$name" '.[$k] | type' <<<"$vars")
      case "$type" in
        'String!') [ "$actual" = string ] || { printf 'gh: Variable $%s of type String! was provided invalid value (got %s)\n' "$name" "$actual" >&2; exit 1; } ;;
        'Int!') [ "$actual" = number ] || { printf 'gh: Variable $%s of type Int! was provided invalid value (got %s)\n' "$name" "$actual" >&2; exit 1; } ;;
      esac
    done < <(printf '%s' "$query" | grep -o '\$[a-zA-Z]*:[A-Za-z]*!' | sed 's/^\$//' | sort -u)
    case " $query " in
      *isRequired*)
        [ -z "${FM_TEST_GH_REQUIRED_FAIL:-}" ] || { printf 'gh: HTTP 502\n' >&2; exit 1; }
        [ -f "${FM_TEST_GH_REQUIRED_JSON:-}" ] || { printf 'gh: no required payload\n' >&2; exit 1; }
        jq -r "$jqprog" < "$FM_TEST_GH_REQUIRED_JSON" || exit 1
        exit 0 ;;
    esac
    cat "$FM_TEST_GH_OUTCOME"; exit 0 ;;
  api\ *) cat "$FM_TEST_GH_RULES"; exit 0 ;;
esac
exit 0
SH
cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") printf 'pull_request:\n  number: %s\n  state: merged\n' "$3" ;;
esac
exit 0
SH
chmod +x "$case_dir/fakebin/gh" "$case_dir/fakebin/gh-axi"

FM_ROOT_OVERRIDE="$ROOT" \
FM_HOME="$case_dir/home" \
FM_STATE_OVERRIDE="$case_dir/state" \
FM_TEST_GH_LOG="$case_dir/gh.log" \
FM_TEST_GH_OUTCOME="$case_dir/github-outcome" \
FM_TEST_GH_RULES="$case_dir/github-rules" \
FM_TEST_GH_VIEW_JSON="$case_dir/github-view.json" \
FM_TEST_GH_HEAD="$case_dir/github-head" \
FM_TEST_GH_REQUIRED_JSON="$case_dir/github-required.json" \
FM_TEST_GH_REQUIRED_FAIL="${FM_DRIVE_REQUIRED_FAIL:-}" \
FM_GATE_REFUSE_BYPASS=1 \
HOME="$case_dir/user-home" \
PATH="$case_dir/fakebin:$PATH" \
  "$SCRIPT" task-x1 "$url" "$@" > "$case_dir/stdout" 2> "$case_dir/stderr"
rc=$?
echo "--- exit: $rc"
echo "--- stderr:"; cat "$case_dir/stderr"
echo "--- gh calls:"; grep -E '^pr merge|^api graphql' "$case_dir/gh.log" | cut -c1-120
exit "$rc"
