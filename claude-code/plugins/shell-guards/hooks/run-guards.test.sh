#!/usr/bin/env bash
# Checks run-guards.sh, the entry point every harness calls: one denied command per guard
# reaches the harness in both protocols, an allowed command passes, a guard subset runs only
# that subset, and a guard that crashes allows. Each guard's own matrix is in its own test.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
RUN="$DIR/run-guards.sh"

FIXTURES=$(mktemp -d)
trap 'rm -rf "$FIXTURES"' EXIT
# The two pydantic-ai guards are scoped by the cwd repo's remote URL.
PYAI="$FIXTURES/pydantic-ai"
mkdir -p "$PYAI" && git -C "$PYAI" init -q && git -C "$PYAI" remote add origin https://github.com/pydantic/pydantic-ai.git
# Pinned after mktemp, which honors TMPDIR on Linux.
export HOME=/fixture-home TMPDIR=/fixture-tmp RECURSIVE_DELETE_ROOTS=/fixture-home/code

fails=0
check() {  # <want blocked> <label> <cwd> <payload> [guard ...]
  local want=$1 label=$2 dir=$3 payload=$4 claude codex out reason
  shift 4
  out=$(cd "$dir" && printf '%s' "$payload" | bash "$RUN" "$@" 2>"$FIXTURES/stderr")
  [ $? -eq 2 ] && claude=true || claude=false
  reason=$(cat "$FIXTURES/stderr")
  if [ "$claude" = true ] && [ "$(jq -r '.reason' <<< "$out")" != "$reason" ]; then
    echo "FAIL stdout reason differs from stderr  $label"
    fails=$((fails + 1))
  fi
  codex=$(cd "$dir" && printf '%s' "$payload" | bash "$RUN" --protocol codex "$@" 2>/dev/null \
    | jq -r 'try .hookSpecificOutput.permissionDecision catch ""')
  [ "$codex" = deny ] && codex=true || codex=false
  if [ "$claude" = "$want" ] && [ "$codex" = "$want" ]; then
    echo "ok   [$want] $label"
  else
    echo "FAIL want=$want claude=$claude codex=$codex  $label"
    fails=$((fails + 1))
  fi
}

shell() { jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c},cwd:"/fixture-home/code"}'; }

check true  'force push'          "$FIXTURES" "$(shell 'git push --force')"
check true  'busy loop'           "$FIXTURES" "$(shell 'while kill -0 $pid; do :; done')"
check true  'broad pkill'         "$FIXTURES" "$(shell 'pkill -f worker')"
check true  'heavy tests'         "$PYAI"     "$(shell 'uv run pytest -n auto')"
check true  'broad typecheck'     "$PYAI"     "$(shell 'uv run pyright')"
check true  'recursive delete'    "$FIXTURES" "$(shell 'rm -rf /fixture-home/notes')"
check false 'ordinary command'    "$PYAI"     "$(shell 'uv run pytest tests/test_x.py')"
check false 'heavy tests outside pydantic-ai' "$FIXTURES" "$(shell 'uv run pytest -n auto')"
check false 'structured edit tool' "$FIXTURES" '{"tool_name":"Edit","tool_input":{"command":"git push --force"}}'

# Grok and Codex payload shapes reach every guard.
check true  'grok payload'        "$FIXTURES" '{"toolName":"run_terminal_command","toolInput":{"command":"git push --force"}}'
check true  'codex payload'       "$FIXTURES" '{"tool_name":"exec_command","tool_input":{"cmd":"git push --force"}}'

# A subset runs only the guards it names.
check false 'subset skips force push'  "$FIXTURES" "$(shell 'git push --force')" block-busy-loop.sh
check true  'subset runs busy loop'    "$FIXTURES" "$(shell 'while kill -0 $pid; do :; done')" block-busy-loop.sh

# A guard that cannot run allows the command rather than blocking it.
check false 'missing guard allows'     "$FIXTURES" "$(shell 'git push --force')" no-such-guard.sh

echo
[ "$fails" -eq 0 ] && echo "all passing" || echo "$fails failing"
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
