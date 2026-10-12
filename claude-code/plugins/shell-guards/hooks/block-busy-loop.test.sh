#!/usr/bin/env bash
# Runs block-busy-loop.sh over its case matrix.
#
# The hook is global (no repo scope), so there is no scope fixture and no in_scope column.
# Cases are asserted against the default Claude/Grok/mastracode deny protocol (message on
# stderr, exit 2); the --protocol codex branch is the same shape as in block-heavy-tests.sh.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/block-busy-loop.sh"
CASES="$DIR/block-busy-loop.cases.json"

fails=0
while IFS=$'\t' read -r cmd want; do
  payload=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')

  printf '%s' "$payload" | bash "$HOOK" >/dev/null 2>&1
  [ $? -eq 2 ] && got=true || got=false

  if [ "$got" = "$want" ]; then
    echo "ok   [$want] $cmd"
  else
    echo "FAIL want=$want got=$got  $cmd"
    fails=$((fails + 1))
  fi
done < <(jq -r '.cases[] | [.command, (.blocked|tostring)] | @tsv' "$CASES")

echo
[ "$fails" -eq 0 ] && echo "all passing" || echo "$fails failing"
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
