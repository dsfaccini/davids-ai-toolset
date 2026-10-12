#!/usr/bin/env bash
# Runs disallow-recursive-delete.py over its case matrix, in both harness protocols, then
# checks the payload shapes the other harnesses send.
#
# Every verdict depends on HOME, TMPDIR and RECURSIVE_DELETE_ROOTS, so the runner pins all
# three to paths that do not exist. Nothing is created or deleted.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/disallow-recursive-delete.py"
CASES="$DIR/disallow-recursive-delete.cases.json"
export HOME=/fixture-home TMPDIR=/fixture-tmp RECURSIVE_DELETE_ROOTS='/fixture-home/code:~/scratch'

fails=0
report() {  # <want> <claude> <codex> <label>
  if [ "$2" = "$1" ] && [ "$3" = "$1" ]; then
    echo "ok   [$1] $4"
  else
    echo "FAIL want=$1 claude=$2 codex=$3  $4"
    fails=$((fails + 1))
  fi
}

verdicts() {  # <payload> -> prints "<claude> <codex>"
  local claude codex
  printf '%s' "$1" | python3 "$HOOK" >/dev/null 2>&1
  [ $? -eq 2 ] && claude=true || claude=false
  codex=$(printf '%s' "$1" | python3 "$HOOK" --protocol codex 2>/dev/null \
    | jq -r 'try .hookSpecificOutput.permissionDecision catch ""')
  [ "$codex" = deny ] && codex=true || codex=false
  echo "$claude $codex"
}

while IFS= read -r case_json; do
  cmd=$(jq -r '.command' <<< "$case_json")
  want=$(jq -r '.blocked' <<< "$case_json")
  payload=$(jq -c '{tool_input:{command:.command}, cwd:(.cwd // "/fixture-home/code")}' <<< "$case_json")
  read -r claude codex <<< "$(verdicts "$payload")"
  report "$want" "$claude" "$codex" "$cmd"
done < <(jq -c '.cases[]' "$CASES")

# Grok sends camelCase keys, Codex names the command `cmd`, and structured edit tools pass.
read -r claude codex <<< "$(verdicts '{"toolName":"run_terminal_command","toolInput":{"command":"rm -rf /fixture-home/notes"},"cwd":"/fixture-home/code"}')"
report true "$claude" "$codex" "grok payload (toolInput)"
read -r claude codex <<< "$(verdicts '{"tool_name":"exec_command","tool_input":{"cmd":"rm -rf /fixture-home/notes","workdir":"/fixture-home/code"}}')"
report true "$claude" "$codex" "codex payload (cmd)"
read -r claude codex <<< "$(verdicts '{"tool_name":"exec_command","tool_input":{"cmd":"rm -rf build","workdir":"/fixture-home/code"}}')"
report false "$claude" "$codex" "codex workdir inside a root"
read -r claude codex <<< "$(verdicts '{"tool_name":"Edit","tool_input":{"command":"rm -rf /fixture-home/notes"}}')"
report false "$claude" "$codex" "tool_name=Edit"

# The deny reason names the approved roots, so the agent can tell the user what to change.
reason=$(jq -nc '{tool_input:{command:"rm -rf /fixture-home/notes"}, cwd:"/fixture-home/code"}' \
  | python3 "$HOOK" 2>&1 >/dev/null)
if [[ "$reason" == *"/fixture-home/code"* && "$reason" == *RECURSIVE_DELETE_ROOTS* ]]; then
  echo "ok   deny reason lists the approved roots"
else
  echo "FAIL deny reason does not list the approved roots: $reason"
  fails=$((fails + 1))
fi

echo
[ "$fails" -eq 0 ] && echo "all passing" || echo "$fails failing"
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
