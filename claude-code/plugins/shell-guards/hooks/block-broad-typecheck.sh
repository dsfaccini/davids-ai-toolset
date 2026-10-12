#!/usr/bin/env bash
# Block whole-repo type checking in pydantic-ai. Measured on a pydantic-ai worktree:
#   whole-repo `uv run pyright`  -> 3.0 GB peak node heap, ~10 min
#   targeted   `uv run pyright <files>` -> 1.0 GB peak, ~1 min
# Several agents doing the former at once is what fills RAM. Node's default heap
# limit here is 4.2 GB, so one run climbs almost that far before V8 collects hard.
#
# Blocked:
#   - make typecheck / typecheck-pyright / typecheck-mypy / typecheck-both
#   - pyright with no target path (whole project), incl. flags-only and --watch
# Allowed:
#   - pyright with explicit file/dir targets
#   - pyright --version / --help (no analysis)
#
# Scope: pydantic-ai worktrees, forks, and Codex's pydantic-ai worktrees. Gates the agent's shell
# tool, not the user's own terminal.
#
# Hook protocol: reads JSON on stdin with .tool_input.command; exit 2 to block.

set -u

# Harnesses disagree on how a PreToolUse hook says "no":
#   Claude Code / Grok Build -- message on stderr, exit 2
#   Codex                    -- hookSpecificOutput JSON on stdout, exit 0
PROTOCOL=claude
[ "${1:-}" = "--protocol" ] && [ "${2:-}" = codex ] && PROTOCOL=codex

# Codex currently dispatches this hook for every tool. These tool names carry
# structured edits, not shell commands. An absent or unknown name stays checked.
INPUT=$(cat)
TOOL_NAME=$(jq -r '.tool_name // .toolName // ""' <<< "$INPUT")
case "$TOOL_NAME" in
  apply_patch | ApplyPatch | Edit | Write) exit 0 ;;
esac

# Scope: any worktree of the pydantic-ai or pydantic-ai-harness repos, wherever it sits on
# disk. Identity comes from the remote URLs, so clones, forks, and the harnesses' own worktree
# dirs are all covered without hardcoding a path. Gates the agent's shell tool, not the user's
# own terminal.
# (Duplicated in block-heavy-tests.sh rather than sourced, so each guard stays
# self-contained when it is copied or symlinked on its own.)
in_pyai_repo() {
  git config --get-regexp '^remote\..*\.url' 2>/dev/null \
    | sed 's/.*[/:]//; s/\.git$//' \
    | grep -qxE 'pydantic-ai|pydantic-ai-harness'
}

CMD=$(jq -r '.tool_input.command // .tool_input.cmd // .toolInput.command // ""' <<< "$INPUT")
[ -n "$CMD" ] || exit 0

shell_command_text() {
  local text=$1
  local line output="" code_text="" quote="" character next_character previous_character
  local nested_text="" current_segment capture_nested=false
  local heredoc_delimiter="" heredoc_line heredoc_strip_tabs="" heredoc_quote=""
  local index heredoc_index heredoc_character
  local single_quote double_quote
  single_quote=$(printf "\\047")
  double_quote=$(printf "\\042")

  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$heredoc_delimiter" ]; then
      heredoc_line=$line
      if [ "$heredoc_strip_tabs" = - ]; then
        while [[ "$heredoc_line" = $'\t'* ]]; do heredoc_line=${heredoc_line#$'\t'}; done
      fi
      [ "$heredoc_line" = "$heredoc_delimiter" ] && heredoc_delimiter=""
      continue
    fi
    code_text+="$line"$'\n'
    for ((index = 0; index < ${#line}; index += 1)); do
      character=${line:index:1}
      if [ -n "$quote" ]; then
        if [ "$character" = "$quote" ]; then
          quote=""
          if [ "$capture_nested" = true ]; then
            output+=" ; $(shell_command_text "$nested_text")"
            nested_text=""
            capture_nested=false
          fi
        elif [ "$capture_nested" = true ]; then
          nested_text+=$character
        fi
        continue
      fi
      if [ "$character" = "$single_quote" ] || [ "$character" = "$double_quote" ]; then
        current_segment=$output
        current_segment=${current_segment##*;}
        current_segment=${current_segment##*|}
        current_segment=${current_segment##*&}
        current_segment=${current_segment##*$'\n'}
        if [[ "$current_segment" =~ ^[[:space:]]*((([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+)[[:space:]]+)|(env[[:space:]]+))*((bash|sh|zsh|dash)[[:space:]]+(-[A-Za-z]*c[A-Za-z]*|--command)[[:space:]]*)$ ]]; then
          capture_nested=true
          nested_text=""
        else
          output+="__literal__"
        fi
        quote=$character
        continue
      fi
      if [ "$character" = "\\" ]; then
        next_character=${line:index + 1:1}
        output+="$character$next_character"
        ((index += 1))
        continue
      fi
      if [ "$character" = '#' ]; then
        previous_character=${line:index - 1:1}
        if [ "$index" -eq 0 ] || [[ "$previous_character" =~ [[:space:]] ]]; then
          break
        fi
      fi
      if [ "$character" = '<' ] && [ "${line:index + 1:1}" = '<' ]; then
        heredoc_index=$((index + 2))
        heredoc_strip_tabs=""
        if [ "${line:heredoc_index:1}" = - ]; then
          heredoc_strip_tabs=-
          ((heredoc_index += 1))
        fi
        while [ "$heredoc_index" -lt "${#line}" ] && [[ "${line:heredoc_index:1}" =~ [[:space:]] ]]; do
          ((heredoc_index += 1))
        done
        heredoc_quote=""
        if [ "${line:heredoc_index:1}" = "$single_quote" ] || [ "${line:heredoc_index:1}" = "$double_quote" ]; then
          heredoc_quote=${line:heredoc_index:1}
          ((heredoc_index += 1))
        fi
        heredoc_delimiter=""
        while [ "$heredoc_index" -lt "${#line}" ]; do
          heredoc_character=${line:heredoc_index:1}
          if [ -n "$heredoc_quote" ]; then
            [ "$heredoc_character" = "$heredoc_quote" ] && { ((heredoc_index += 1)); break; }
          else
            case "$heredoc_character" in
              [[:space:]] | ';' | '|' | '&' | '<' | '>') break ;;
            esac
          fi
          heredoc_delimiter+=$heredoc_character
          ((heredoc_index += 1))
        done
        [ -n "$heredoc_delimiter" ] || heredoc_strip_tabs=""
        index=$((heredoc_index - 1))
        continue
      fi
      output+=$character
    done
    output+=$'\n'
  done <<< "$text"
  output+=$(command_substitution_text "$code_text")
  printf '%s' "$output"
}

command_substitution_end() {  # <text> <first character after $(>
  local text=$1 index=$2 character quote="" depth=1
  local single_quote double_quote
  single_quote=$(printf "\\047")
  double_quote=$(printf "\\042")
  while [ "$index" -lt "${#text}" ]; do
    character=${text:index:1}
    if [ -n "$quote" ]; then
      if [ "$character" = "\\" ] && [ "$quote" = "$double_quote" ]; then
        ((index += 2))
        continue
      fi
      [ "$character" = "$quote" ] && quote=""
      ((index += 1))
      continue
    fi
    if [ "$character" = "\\" ]; then
      ((index += 2))
      continue
    fi
    if [ "$character" = "$single_quote" ] || [ "$character" = "$double_quote" ]; then
      quote=$character
    elif [ "$character" = '(' ]; then
      ((depth += 1))
    elif [ "$character" = ')' ]; then
      ((depth -= 1))
      if [ "$depth" -eq 0 ]; then
        REPLY=$index
        return
      fi
    fi
    ((index += 1))
  done
  REPLY=""
}

command_substitution_text() {
  local text=$1 output="" quote="" character nested_text=""
  local index nested_start nested_index
  local single_quote double_quote backtick
  single_quote=$(printf "\\047")
  double_quote=$(printf "\\042")
  backtick=$(printf "\\140")

  for ((index = 0; index < ${#text}; index += 1)); do
    character=${text:index:1}
    if [ "$quote" = "$single_quote" ]; then
      [ "$character" = "$single_quote" ] && quote=""
      continue
    fi
    if [ "$quote" = "$double_quote" ]; then
      if [ "$character" = "\\" ]; then
        ((index += 1))
        continue
      fi
      if [ "$character" = "$double_quote" ]; then
        quote=""
        continue
      fi
    else
      if [ "$character" = "\\" ]; then
        ((index += 1))
        continue
      fi
      if [ "$character" = "$single_quote" ] || [ "$character" = "$double_quote" ]; then
        quote=$character
        continue
      fi
    fi
    if [ "$character" = '$' ] && [ "${text:index + 1:1}" = '(' ]; then
      nested_start=$((index + 2))
      command_substitution_end "$text" "$nested_start"
      if [ -n "$REPLY" ]; then
        nested_text=${text:nested_start:REPLY - nested_start}
        output+=" ; $(shell_command_text "$nested_text")"
        index=$REPLY
      else
        output+=" ; $(shell_command_text "${text:nested_start}")"
        break
      fi
    elif [ "$character" = "$backtick" ]; then
      nested_start=$((index + 1))
      nested_index=$nested_start
      while [ "$nested_index" -lt "${#text}" ]; do
        character=${text:nested_index:1}
        if [ "$character" = "\\" ]; then
          ((nested_index += 2))
          continue
        fi
        [ "$character" = "$backtick" ] && break
        ((nested_index += 1))
      done
      if [ "$nested_index" -lt "${#text}" ]; then
        nested_text=${text:nested_start:nested_index - nested_start}
        output+=" ; $(shell_command_text "$nested_text")"
        index=$nested_index
      else
        output+=" ; $(shell_command_text "${text:nested_start}")"
        break
      fi
    fi
  done
  printf '%s' "$output"
}

CMD=$(shell_command_text "$CMD")
CMD=$(printf '%s\n' "$CMD" \
  | tr '|;&' '\n\n\n' \
  | sed -E 's/[[:space:]][0-9]*>>?([[:space:]]*[^[:space:]]+)?//g; s/[[:space:]][0-9]*>&[0-9]+//g' \
  | grep -E '^[[:space:]]*((([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+)[[:space:]]+)|(env[[:space:]]+))*(([^[:space:]]+/)?make[[:space:]]+typecheck(-pyright|-mypy|-both)?|([^[:space:]]+/)?pyright([[:space:]]|$)|uv[[:space:]]+run[[:space:]]+([^[:space:]]+/)?pyright([[:space:]]|$))' || true)
[ -n "$CMD" ] || exit 0

# Cheap pre-filter before the git call: most commands can never trip a rule below.
echo "$CMD" | grep -qE '(pyright|mypy|make)' || exit 0

in_pyai_repo || exit 0

_deny() {
  local msg="$1"
  if [ "$PROTOCOL" = codex ]; then
    jq -nc --arg reason "$msg" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
    exit 0
  fi
  echo "$msg" >&2
  jq -nc --arg reason "$msg" '{decision: "deny", reason: $reason}' 2>/dev/null || true
  exit 2
}

_advice() {
  cat <<EOF
Blocked: $1 — whole-repo type checking peaks around 3 GB and runs ~10 minutes, and several agents doing it at once fills the machine's RAM.
Typecheck the files you changed instead:
  PYRIGHT_PYTHON_IGNORE_WARNINGS=1 uv run pyright path/to/changed.py tests/test_changed.py
Whole-repo pyright runs in CI's lint job.
EOF
}

echo "$CMD" | grep -qE '(^|[|;&[:space:]/])make[[:space:]]+typecheck(-pyright|-mypy|-both)?\b' \
  && _deny "$(_advice 'make typecheck')"

# Walk the tokens after each `pyright` to decide whether a target path was given.
# Flags that consume a following value must not be mistaken for a target.
PYRIGHT_VERDICT=$(printf '%s' "$CMD" | tr '|;&' '\n\n\n' | awk '
  function base(s) { sub(/.*\//, "", s); return s }
  {
    for (i = 1; i <= NF; i++) {
      if (base($i) != "pyright") continue
      targeted = 0
      for (j = i + 1; j <= NF; j++) {
        a = $j
        if (a == "--version" || a == "--help" || a == "-h" || a == "--createstub") { targeted = 1; break }
        if (a ~ /^-/) {
          # value-taking flags: skip their argument unless it is attached with =
          if (a !~ /=/ && a ~ /^(--project|--pythonpath|--pythonplatform|--pythonversion|--typeshedpath|--venvpath|--level|--outputformat|-p|-t|-v)$/) j++
          # --threads takes an optional count; only a numeric next token is its value
          else if (a == "--threads" && $(j + 1) ~ /^[0-9]+$/) j++
          continue
        }
        targeted = 1; break
      }
      if (!targeted) { print "broad"; exit }
    }
  }')

[ "$PYRIGHT_VERDICT" = broad ] \
  && _deny "$(_advice 'pyright with no target files (whole project)')"

exit 0
