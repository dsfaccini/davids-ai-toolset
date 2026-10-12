#!/usr/bin/env bash
# Runs block-broad-pkill.sh over its case matrix.
#
# The hook is global (no repo scope), so there is no scope fixture and no in_scope column.
# Cases are asserted against the default Claude/Grok/mastracode deny protocol (message on
# stderr, exit 2), then one case checks the Codex deny shape.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/block-broad-pkill.sh"
CASES="$DIR/block-broad-pkill.cases.json"

fails=0
# One JSON case per line: @tsv would flatten a heredoc's newlines into a literal `\n`.
while IFS= read -r case_json; do
  cmd=$(jq -r '.command' <<< "$case_json")
  want=$(jq -r '.blocked' <<< "$case_json")

  jq -c '{tool_input:{command:.command}}' <<< "$case_json" | bash "$HOOK" >/dev/null 2>&1
  [ $? -eq 2 ] && got=true || got=false

  if [ "$got" = "$want" ]; then
    echo "ok   [$want] ${cmd//$'\n'/ ⏎ }"
  else
    echo "FAIL want=$want got=$got  ${cmd//$'\n'/ ⏎ }"
    fails=$((fails + 1))
  fi
done < <(jq -c '.cases[]' "$CASES")

decision=$(jq -nc '{tool_name:"exec_command",tool_input:{cmd:"pkill -f cat"}}' \
  | bash "$HOOK" --protocol codex | jq -r '.hookSpecificOutput.permissionDecision // "allow"')
if [ "$decision" = deny ]; then
  echo "ok   [codex deny] pkill -f cat"
else
  echo "FAIL codex protocol: want deny, got $decision"
  fails=$((fails + 1))
fi

echo
[ "$fails" -eq 0 ] && echo "all passing" || echo "$fails failing"
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
