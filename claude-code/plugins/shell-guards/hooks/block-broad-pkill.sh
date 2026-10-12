#!/usr/bin/env bash
# Block process-kill commands whose match set reaches far past the intended target:
#   1. pkill -f: the pattern is matched against every process's full command line, so
#      `pkill -f cat` hits every path containing "Applications", "Notifications", ...
#   2. killall -m: the name is matched as a regular expression, with the same reach.
#   3. an option after the pattern: BSD pkill stops parsing options at the first operand,
#      so `pkill -f cat -P $$` reads `-P` and `$$` as two more patterns and never limits
#      the kill to the shell's children.
# pgrep only lists. It is checked by the same rules only when its output is captured
# (`$(...)`, backticks, `| xargs`) in a command that also runs `kill`, because then its output
# picks what dies (`kill $(pgrep -f cat)`, `pgrep -f cat | xargs kill`).
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

# Heredoc bodies are data, not commands: a commit message or script that mentions
# `pkill -f` must not read as running it. The line carrying `<<DELIM` is kept.
CMD=$(printf '%s\n' "$CMD" | awk '
inhd { t = $0; sub(/^[[:space:]]+/, "", t); if (t == delim) inhd = 0; next }
{
    if (match($0, /<<-?[[:space:]]*[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
        d = substr($0, RSTART, RLENGTH)
        sub(/^<<-?[[:space:]]*/, "", d)
        gsub(/[\047"]/, "", d)
        delim = d
        inhd = 1
    }
    print
}
')

echo "$CMD" | grep -qE '(^|[^[:alnum:]_.-])(pkill|pgrep|killall)([[:space:]]|$)' || exit 0

FEEDS_KILL=false
echo "$CMD" | grep -qE '(^|[^[:alnum:]_.-])kill([[:space:]]|$)' && FEEDS_KILL=true

block() {
  local msg
  msg=$(cat <<'EOF'
Blocked: this command can signal far more processes than you intend.
  - pkill -f matches the pattern against every process's full command line.
    A short pattern such as "cat" matches every path under /Applications.
  - killall -m matches the name as a regular expression, with the same reach.
  - pkill stops reading options at the pattern. An option after the pattern becomes
    another pattern: `pkill -f cat -P $$` ignores -P and matches "-P" and the PID.
  - pgrep has the same rules when its output feeds kill.
Do this instead:
  1. In a separate command, list the candidates: pgrep -lf <pattern>
  2. Kill only the PIDs you started: kill <pid>
To kill by exact process name, put every option first: pkill -P <ppid> -x <name>
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

# Emulates BSD getopt over one command's words: options end at the first operand or `--`.
check_words() {
  local kind=$1; shift
  local operand_seen=false w opts c k
  while [ $# -gt 0 ]; do
    w=$1; shift
    [ "$w" = "--" ] && return
    case "$w" in
      -?*) ;;
      *) operand_seen=true; continue ;;
    esac
    $operand_seen && [ "$kind" != killall ] && block
    if [ "$kind" = killall ]; then
      [[ "$w" =~ ^-[a-z]*m[a-z]*$ ]] && block
      continue
    fi
    [ "$w" = "--full" ] && block
    # A signal (`-9`, `-KILL`, `-SIGTERM`) is not an option cluster.
    [[ "$w" =~ ^-([0-9]+|[A-Z][A-Z0-9]+)$ ]] && continue
    opts=${w#-}
    for ((k = 0; k < ${#opts}; k++)); do
      c=${opts:k:1}
      [ "$c" = f ] && block
      # An option that takes a value consumes the rest of the cluster, or the next word.
      case "$c" in
        [FGJMNPUgstu])
          [ "$k" -eq $((${#opts} - 1)) ] && [ $# -gt 0 ] && shift
          break ;;
      esac
    done
  done
}

# Split into simple commands: control operators, redirections, command substitution and
# grouping all end one. Quotes are dropped first so a quoted pattern stays one segment.
# A segment whose output is captured is tagged: @CAPTURED@ opens a `$(...)` or backtick
# segment and closes one piped into xargs.
SEGMENTS=$(echo "$CMD" | tr -d "\"'" | sed -E '
  s/\|[[:space:]]*xargs/ @CAPTURED@\nxargs/g
  s/(\$\(|`)/\n@CAPTURED@ /g
  s/[0-9]?>>?/\n/g
  s/[|;&(){}<]/\n/g')

while IFS= read -r segment; do
  read -ra words <<< "$segment"
  i=0
  # Skip env assignments and wrappers (with their flags and numeric values) before the command word.
  while [ "$i" -lt "${#words[@]}" ]; do
    case "${words[$i]}" in
      *=* | -* | [0-9]* | @CAPTURED@ | sudo | doas | command | exec | nohup | time | env | xargs | timeout | nice) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "${#words[@]}" ] || continue
  case "${words[$i]##*/}" in
    pkill) check_words pkill "${words[@]:i+1}" ;;
    pgrep)
      $FEEDS_KILL && [[ " $segment " == *" @CAPTURED@ "* ]] && check_words pgrep "${words[@]:i+1}" ;;
    killall) check_words killall "${words[@]:i+1}" ;;
  esac
done <<< "$SEGMENTS"

exit 0
