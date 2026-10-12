#!/usr/bin/env bash
# Runs the guards in this folder over one PreToolUse payload. The first guard that denies
# decides, and its reason is passed on in the protocol the harness speaks:
#   default          -- reason on stderr plus {"decision":"deny"} JSON on stdout, exit 2
#                       (Claude Code, Grok Build, mastracode, and the pi and opencode adapters)
#   --protocol codex -- hookSpecificOutput JSON on stdout, exit 0
#
# Usage: run-guards.sh [--protocol codex] [guard file ...]
# With no guard files it runs every guard. A guard that fails for any other reason (a missing
# jq or python3, a crash) allows the command, as Claude Code treats a non-2 exit.
set -u
HOOKS="$(cd "$(dirname "$0")" && pwd)"

PROTOCOL=claude
if [ "${1:-}" = "--protocol" ] && [ "${2:-}" = codex ]; then
  PROTOCOL=codex
  shift 2
fi

GUARDS=("$@")
[ "${#GUARDS[@]}" -gt 0 ] || GUARDS=(
  block-force-push.sh
  block-busy-loop.sh
  block-broad-pkill.sh
  block-heavy-tests.sh
  block-broad-typecheck.sh
  disallow-recursive-delete.py
)

INPUT=$(cat)

for guard in "${GUARDS[@]}"; do
  case "$guard" in
    *.py) interpreter=python3 ;;
    *) interpreter=bash ;;
  esac
  reason=$(printf '%s' "$INPUT" | "$interpreter" "$HOOKS/$guard" 2>&1 >/dev/null)
  [ $? -eq 2 ] || continue

  if [ "$PROTOCOL" = codex ]; then
    jq -nc --arg reason "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
    exit 0
  fi
  printf '%s\n' "$reason" >&2
  jq -nc --arg reason "$reason" '{decision: "deny", reason: $reason}' 2>/dev/null || true
  exit 2
done

exit 0
