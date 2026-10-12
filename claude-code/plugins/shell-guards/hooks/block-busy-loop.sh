#!/usr/bin/env bash
# Block shell busy-wait loops in the agent's shell tool — they pin a CPU core.
# The footgun: a loop with a NON-BLOCKING condition and no `sleep`, e.g.
#   while kill -0 $pid; do :; done          # spins a core until pid dies
#   until [ -f /tmp/done ]; do :; done       # spins a core polling a file
# Blocking loops (`while read line; do ...`) are fine — read blocks, doesn't spin.
#
# Scope: global, the agent's shell tool only (the user's own terminal is untouched).
# Hook protocol: reads JSON on stdin with the command under .tool_input.command
# (.tool_input.cmd / .toolInput.command on the harnesses that name it differently).
set -u

# Harnesses disagree on how a PreToolUse hook says "no":
#   Claude Code / Grok Build / mastracode -- message on stderr, exit 2
#   Codex                                 -- hookSpecificOutput JSON on stdout, exit 0
# `--protocol codex` selects the latter. Default stays Claude/Grok/mastracode.
PROTOCOL=claude
[ "${1:-}" = "--protocol" ] && [ "${2:-}" = codex ] && PROTOCOL=codex

# Codex currently dispatches this hook for every tool. These tool names carry
# structured edits, not shell commands. An absent or unknown name stays checked.
INPUT=$(cat)
TOOL_NAME=$(jq -r '.tool_name // .toolName // ""' <<< "$INPUT")
case "$TOOL_NAME" in
  apply_patch | ApplyPatch | Edit | Write) exit 0 ;;
esac

CMD=$(jq -r '.tool_input.command // .tool_input.cmd // .toolInput.command // ""' <<< "$INPUT")

# Only consider commands with a while/until loop.
echo "$CMD" | grep -qE '(^|[|;&[:space:]])(while|until)\b' || exit 0

# A `sleep` or `wait` anywhere means it yields the core — allowed.
echo "$CMD" | grep -qE '(^|[|;&[:space:]])(sleep|wait)\b' && exit 0

# `read`-driven loops block on input, they don't spin — allowed.
echo "$CMD" | grep -qE '(while|until)[[:space:]]+(read\b|.*[|][[:space:]]*read\b)' && exit 0

block() {
  local msg
  msg=$(cat <<'EOF'
Blocked: busy-wait loop pins a CPU core (spins with no sleep). This is the exact
pattern that ran a zsh at 100% for hours.
  - To wait on a background job/PID, use: wait <pid>
  - To poll for a condition, put a `sleep 1` (or more) inside the loop body.
  - To wait for a background task YOU started via the Bash tool: don't poll at all —
    the harness re-invokes you with a completion notification when it finishes.
EOF
)
  if [ "$PROTOCOL" = codex ]; then
    jq -nc --arg reason "$msg" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
    exit 0
  fi
  echo "$msg" >&2
  jq -nc --arg reason "$msg" '{decision: "deny", reason: $reason}' 2>/dev/null || true
  exit 2
}

# No-op spin body: `do :` or `do true` (the classic core-burner).
echo "$CMD" | grep -qE ';[[:space:]]*do[[:space:]]+(:|true)[[:space:]]*;' && block

# Non-blocking liveness/condition poll with no sleep in the loop.
echo "$CMD" | grep -qE '(while|until)[[:space:]].*\b(kill[[:space:]]+-0|pgrep|pkill[[:space:]]+-0|ps[[:space:]]+-p|test[[:space:]]+-|\[[[:space:]]+-[ef])\b' && block

exit 0
