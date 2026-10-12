#!/usr/bin/env bash
# Block heavy local test runs in pydantic-ai that spawn multi-GB process fleets:
#   - make test / testcov / test-all-python / all  (xdist + coverage + the 3.10->3.13 matrix)
#   - pytest with xdist parallelism (-n / --numprocesses): one worker per core, each loads the whole app
#   - full-suite coverage run and pytest --cov
#   - tox / nox (local CI across python versions)
#
# Allowed (carve-outs):
#   - targeted pytest: `uv run pytest tests/foo.py::test_bar` (no -n, no --cov)
#   - single-file / targeted coverage diagnostics WITHOUT xdist, e.g.:
#       uv run coverage run -m pytest tests/foo.py -p no:randomly -q
#     (still blocked with -n/--numprocesses)
#
# Word-boundary matching, so env prefixes (`FOO=1 make test`), `cd x && make test`, and
# path-prefixed binaries (`.venv/bin/coverage run`) all still match.
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
# (Duplicated in block-broad-typecheck.sh rather than sourced, so each guard stays
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
  | grep -E '^[[:space:]]*((([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+)[[:space:]]+)|(env[[:space:]]+))*(([^[:space:]]+/)?make[[:space:]]+(test|testcov|test-all-python|all)([[:space:]]|$)|([^[:space:]]+/)?(tox|nox)([[:space:]]|$)|((uv[[:space:]]+run[[:space:]]+)?([^[:space:]]+/)?coverage[[:space:]]+run)|((uv[[:space:]]+run[[:space:]]+)?([^[:space:]]+/)?pytest([[:space:]]|$)))' || true)
[ -n "$CMD" ] || exit 0

# Cheap pre-filter before the git call: most commands can never trip a rule below.
echo "$CMD" | grep -qE '(pytest|coverage|tox|nox|make)' || exit 0

in_pyai_repo || exit 0

block() {
  local msg
  msg=$(cat <<EOF
Blocked: no full-suite / xdist / multi-python test runs locally — they spawn multi-GB process fleets that overwhelm the machine ($1).
Run targeted tests instead, e.g.:  uv run pytest tests/<file>.py::<test>   (no -n)
Targeted coverage (no xdist) is allowed:  uv run coverage run -m pytest tests/<file>.py -p no:randomly -q
For full coverage or the 3.10->3.13 matrix, push and let CI run it.
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

# make targets that run the whole suite (-n auto), coverage, or the version matrix.
echo "$CMD" | grep -qE '(^|[|;&[:space:]/])make[[:space:]]+(test|testcov|test-all-python|all)\b' \
  && block 'make test/testcov/test-all-python/all'

# tox / nox: local CI across python versions.
echo "$CMD" | grep -qE '(^|[|;&[:space:]/])(tox|nox)\b' \
  && block 'tox/nox'

has_xdist() {
  echo "$CMD" | grep -qE '(^|[[:space:]])(-n[[:space:]=]*(auto|logical|[0-9]+)|--numprocesses\b)'
}

# coverage run: allow only when not under xdist AND a targeted path is present
# (tests/…, a .py file, or pytest node id). Bare `coverage run -m pytest` (whole suite) stays blocked.
if echo "$CMD" | grep -qE '(^|[|;&[:space:]/])coverage[[:space:]]+run\b'; then
  if has_xdist; then
    block 'coverage run with xdist (-n/--numprocesses)'
  fi
  # Targeted if the command mentions a tests path, a .py file, or a node id (::).
  if echo "$CMD" | grep -qE '(tests/|\.py\b|::)'; then
    : # allowed
  else
    block 'coverage run without a targeted tests path (full suite)'
  fi
fi

# pytest-family invocations: block xdist and --cov (coverage instrumentation of the suite).
if echo "$CMD" | grep -qE '(^|[|;&[:space:]/])pytest\b'; then
  if has_xdist; then
    block 'pytest -n/--numprocesses (xdist) spawns one heavy worker per core'
  fi
  if echo "$CMD" | grep -qE '(^|[[:space:]])--cov\b'; then
    block 'pytest --cov runs the suite under coverage instrumentation'
  fi
fi

exit 0
