#!/usr/bin/env bash
# Runs block-broad-typecheck.sh over its case matrix, in both harness protocols.
#
# Scope is repo identity (the cwd repo's remote URLs), so the fixtures are two throwaway
# repos that differ only in their remote name: pydantic-ai (in scope) and pydantic-ai-tooling
# (out of scope — also the regression for the exact match, which must not accept a prefix).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/block-broad-typecheck.sh"
CASES="$DIR/block-broad-typecheck.cases.json"

FIXTURES=$(mktemp -d)
trap 'rm -rf "$FIXTURES"' EXIT
fixture_repo() {  # <dir> <remote url>
  mkdir -p "$1" && git -C "$1" init -q && git -C "$1" remote add origin "$2"
}
IN_SCOPE="$FIXTURES/pydantic-ai"
OUT_SCOPE="$FIXTURES/pydantic-ai-tooling"
fixture_repo "$IN_SCOPE" 'https://github.com/pydantic/pydantic-ai.git'
fixture_repo "$OUT_SCOPE" 'https://github.com/pydantic/pydantic-ai-tooling.git'

fails=0
case_count=$(jq -r '.cases | length' "$CASES")
for ((case_index = 0; case_index < case_count; case_index += 1)); do
  cmd=$(jq -r --argjson index "$case_index" '.cases[$index].command' "$CASES")
  want=$(jq -r --argjson index "$case_index" '.cases[$index].blocked' "$CASES")
  scope=$(jq -r --argjson index "$case_index" 'if .cases[$index] | has("in_scope") then .cases[$index].in_scope else true end' "$CASES")
  dir="$IN_SCOPE"; [ "$scope" = false ] && dir="$OUT_SCOPE"
  payload=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')

  ( cd "$dir" && printf '%s' "$payload" | bash "$HOOK" ) >/dev/null 2>&1
  [ $? -eq 2 ] && got=true || got=false

  out=$( cd "$dir" && printf '%s' "$payload" | bash "$HOOK" --protocol codex 2>/dev/null )
  codex=$(printf '%s' "$out" | jq -r 'try .hookSpecificOutput.permissionDecision catch ""')
  [ "$codex" = deny ] && gotc=true || gotc=false

  if [ "$got" = "$want" ] && [ "$gotc" = "$want" ]; then
    echo "ok   [$want] $cmd"
  else
    echo "FAIL want=$want claude=$got codex=$gotc  $cmd"
    fails=$((fails + 1))
  fi
done

check_tool_name() {  # <name> <want>
  local name="$1" want="$2" payload out codex got gotc
  if [ -n "$name" ]; then
    payload=$(jq -nc --arg n "$name" --arg c "$(jq -r '.cases[0].command' "$CASES")" '{tool_name:$n,tool_input:{command:$c}}')
  else
    payload=$(jq -nc --arg c "$(jq -r '.cases[0].command' "$CASES")" '{tool_input:{command:$c}}')
  fi
  ( cd "$IN_SCOPE" && printf '%s' "$payload" | bash "$HOOK" ) >/dev/null 2>&1
  [ $? -eq 2 ] && got=true || got=false
  out=$( cd "$IN_SCOPE" && printf '%s' "$payload" | bash "$HOOK" --protocol codex 2>/dev/null )
  codex=$(printf '%s' "$out" | jq -r 'try .hookSpecificOutput.permissionDecision catch ""')
  [ "$codex" = deny ] && gotc=true || gotc=false
  if [ "$got" = "$want" ] && [ "$gotc" = "$want" ]; then
    echo "ok   [$want] tool_name=${name:-absent}"
  else
    echo "FAIL want=$want claude=$got codex=$gotc tool_name=${name:-absent}"
    fails=$((fails + 1))
  fi
}

check_tool_name "" true
check_tool_name "future_shell_tool" true
check_tool_name "apply_patch" false
check_tool_name "Edit" false
check_tool_name "Write" false

check_quoted_payload() {  # <shell|print> <want>
  local mode="$1" want="$2" inner command_value payload out codex got gotc
  inner=$(jq -r '.cases[7].command' "$CASES")
  if [ "$mode" = shell ]; then
    command_value="bash -lc '$inner'"
  else
    command_value="printf '%s\\n' '$inner'"
  fi
  payload=$(jq -nc --arg c "$command_value" '{tool_input:{command:$c}}')
  ( cd "$IN_SCOPE" && printf '%s' "$payload" | bash "$HOOK" ) >/dev/null 2>&1
  [ $? -eq 2 ] && got=true || got=false
  out=$( cd "$IN_SCOPE" && printf '%s' "$payload" | bash "$HOOK" --protocol codex 2>/dev/null )
  codex=$(printf '%s' "$out" | jq -r 'try .hookSpecificOutput.permissionDecision catch ""')
  [ "$codex" = deny ] && gotc=true || gotc=false
  if [ "$got" = "$want" ] && [ "$gotc" = "$want" ]; then
    echo "ok   [$want] quoted $mode payload"
  else
    echo "FAIL want=$want claude=$got codex=$gotc quoted $mode payload"
    fails=$((fails + 1))
  fi
}

check_quoted_payload shell true
check_quoted_payload print false

echo
[ "$fails" -eq 0 ] && echo "all passing" || echo "$fails failing"
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
