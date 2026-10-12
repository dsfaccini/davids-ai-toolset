#!/usr/bin/env bash
# Block git force-push (and equivalently-destructive --mirror) in all its forms:
#   1. explicit flags: --force, -f, --force-with-lease, --force-if-includes, --mirror
#   2. +refspec token on the command line (e.g. `git push origin +branch:remote`)
#   3. `+`-prefixed refspec configured in `remote.<name>.push` (silent force)
#   4. git aliases that resolve to any of the above (e.g. `fp = push --force`)
#
# Hook protocol: reads JSON on stdin with .tool_input.command; exit 2 to block.

set -u

# Codex currently dispatches this hook for every tool. These tool names carry
# structured edits, not shell commands. An absent or unknown name stays checked.
INPUT=$(cat)
TOOL_NAME=$(jq -r '.tool_name // .toolName // ""' <<< "$INPUT")
case "$TOOL_NAME" in
  apply_patch | ApplyPatch | Edit | Write) exit 0 ;;
esac

# Claude Code stdin: { tool_input: { command } }
# Codex stdin:       { tool_input: { command | cmd } }
# Grok Build stdin:  { toolInput:  { command } }  (camelCase)
# Empty command → allow (fail-open on malformed payload so non-shell tools aren't blocked).
CMD=$(jq -r '.tool_input.command // .tool_input.cmd // .toolInput.command // ""' <<< "$INPUT")

# 0. Expand git aliases that resolve to `push ...` so the rest of the hook sees
#    the actual flags. Handles direct aliases (`fp = push --force`) and shell-out
#    aliases (`fp = !git push --force`). Single-pass: only the first `git <name>`
#    occurrence is rewritten — sufficient for the common one-off bypass case.
ALIAS_NAME=$(echo "$CMD" | grep -oE '(^|[|;&[:space:]])git[[:space:]]+[A-Za-z0-9_.-]+' | head -1 | sed -E 's/.*git[[:space:]]+//')
if [ -n "$ALIAS_NAME" ] && [ "$ALIAS_NAME" != "push" ]; then
  ALIAS_BODY=$(git config --get "alias.$ALIAS_NAME" 2>/dev/null || true)
  if [ -n "$ALIAS_BODY" ]; then
    # Strip the `!git ` prefix used by shell-out aliases so we can pattern-match the body.
    NORMALIZED=$(echo "$ALIAS_BODY" | sed -E 's/^[[:space:]]*!git[[:space:]]+//; s/^[[:space:]]+//')
    if echo "$NORMALIZED" | grep -qE '^push\b'; then
      # `#` delimiter avoids clashing with `|` alternation in the pattern.
      CMD=$(echo "$CMD" | sed -E "s#(^|[|;&[:space:]])git[[:space:]]+${ALIAS_NAME}([[:space:]]|;|\||&|\$)#\1git ${NORMALIZED}\2#")
    fi
  fi
fi

# Quick gate: only inspect git push commands.
echo "$CMD" | grep -qE '(^|[|;&[:space:]])git[[:space:]]+push\b' || exit 0

# Isolate the `git push` argv segment(s). A compound command routinely carries -f-bearing
# flags belonging to some OTHER command (`rm -rf tmp && git push`, `docker rm -f c; git push`),
# and scanning the whole line reads those as force-push flags. Split on shell control tokens
# and keep only the segments that actually invoke `git push` — checks 1 and 2 then see push
# arguments and nothing else. (Check 3 already stops at control tokens for the same reason.)
# Note this preserves the block on a real force push anywhere in the chain: the segment that
# carries it is itself a `git push` segment and is kept.
PUSH_SEG=$(echo "$CMD" \
  | sed -E 's/(\|\||&&|[|;&]|[0-9]?>>?|<)/\n/g' \
  | grep -E '(^|[[:space:]])git[[:space:]]+push\b')

# 1. Explicit flags. Match --force / --force-with-lease / --force-if-includes,
#    short-form `-f` (alone or bundled like `-uf`), and --mirror (deletes remote
#    refs not present locally — destructive in the same class as force-push).
_deny() {
  local msg="$1"
  # stderr: Claude Code surfaces this to the model
  echo "$msg" >&2
  # stdout JSON: Grok Build PreToolUse deny (also accepted by Claude-compatible runners)
  jq -nc --arg reason "$msg" '{decision: "deny", reason: $reason}' 2>/dev/null || true
  exit 2
}

if echo "$PUSH_SEG" | grep -qE '(--force(-with-lease|-if-includes)?\b|(^|[[:space:]])-[A-Za-z]*f[A-Za-z]*\b|--mirror\b)'; then
  _deny 'Force push blocked: --force / -f / --force-with-lease / --force-if-includes / --mirror detected.'
fi

# 2. `+refspec` token on the command line.
if echo "$PUSH_SEG" | grep -qE '(^|[[:space:]])\+[A-Za-z0-9._/*-]+(:[A-Za-z0-9._/*-]+)?(\b|$)'; then
  _deny 'Force push blocked: refspec begins with `+` (forces non-fast-forward).'
fi

# 3. `+`-prefixed refspec configured for the remote being pushed to.
#    Parse the remote name out of the command (first non-flag arg after `push`); fall back to upstream / origin.
#    Stop at shell control tokens so `git push 2>&1 | tail` doesn't pick `tail`.
REMOTE=$(echo "$CMD" | awk '
  {
    for (i = 1; i <= NF; i++) {
      # Shell control tokens end the `git push` argv segment.
      if ($i ~ /^(\|\|?|;|&&?|<|>>?|2>>?|2>&[0-9]+|>&[0-9]+)$/) break
      if (!found && $i == "push") { found = 1; continue }
      if (found && $i !~ /^-/) { print $i; exit }
    }
  }
')

# If REMOTE was parsed but isn't an actual configured remote (e.g. a `$VAR`,
# `HEAD`, a refspec, or a stray shell token we missed), treat it as unresolved
# so the fallback "scan all remotes" runs.
if [ -n "$REMOTE" ] && ! git remote 2>/dev/null | grep -qx "$REMOTE"; then
  REMOTE=""
fi

if [ -z "$REMOTE" ]; then
  REMOTE=$(git rev-parse --abbrev-ref '@{push}' 2>/dev/null | cut -d/ -f1)
fi

check_remote() {
  local remote="$1"
  if git config --get-all "remote.$remote.push" 2>/dev/null | grep -qE '^\+'; then
    local configured
    configured=$(git config --get-all "remote.$remote.push" | grep -E '^\+' | head -1)
    _deny "Force push blocked: remote.$remote.push is configured with a refspec that begins with +, which forces non-fast-forward on every push (silent force). Offending entry: $configured. Inspect: git config --get-all remote.$remote.push. Fix: re-set the refspec without the leading +, or push to a different remote."
  fi
  return 1
}

if [ -n "$REMOTE" ]; then
  check_remote "$REMOTE"  # _deny exits 2
  exit 0
fi

# Bare `git push` with no resolvable upstream: scan every remote whose push refspec
# would match the current HEAD branch and starts with `+`. Avoids missing the silent-
# force case when @{push} can't be resolved.
HEAD_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null)
if [ -n "$HEAD_BRANCH" ]; then
  while IFS= read -r remote; do
    [ -z "$remote" ] && continue
    while IFS= read -r spec; do
      [ -z "$spec" ] && continue
      src=${spec#+}
      src=${src%%:*}
      if [ "$src" = "$HEAD_BRANCH" ] || [ "$src" = "HEAD" ] || [ "$src" = "refs/heads/$HEAD_BRANCH" ]; then
        check_remote "$remote"  # _deny exits 2
      fi
    done < <(git config --get-all "remote.$remote.push" 2>/dev/null | grep -E '^\+')
  done < <(git remote 2>/dev/null)
fi

exit 0
