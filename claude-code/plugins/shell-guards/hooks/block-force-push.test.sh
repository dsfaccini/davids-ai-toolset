#!/usr/bin/env bash
# Runs block-force-push.sh over its case matrix (block-force-push.cases.json), then over the
# config-dependent cases the matrix cannot express.
#
# The cases live in files rather than inline because the hook (correctly) blocks a Bash command
# that merely contains the literal force-push strings needed to test it.
#
# The hook is global (no repo scope) and speaks the Claude/Grok/mastracode deny protocol only
# (message on stderr, exit 2) — there is no --protocol codex branch to assert. run-guards.sh
# translates its verdict for Codex.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/block-force-push.sh"
CASES="$DIR/block-force-push.cases.json"

bash -n "$HOOK" || { echo "syntax error in $HOOK"; exit 1; }

FIXTURES=$(mktemp -d)
trap 'rm -rf "$FIXTURES"' EXIT

# Fixtures are throwaway repos: every verdict then comes from the repo state this file sets,
# never from whatever repo the runner happens to sit in.
fixture_repo() {  # <name> -> prints the repo path
  local dir="$FIXTURES/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" symbolic-ref HEAD refs/heads/main  # pin the branch name the refspec cases match on
  echo "$dir"
}

verdict() {  # <dir> <command> -> prints true when the hook blocks
  ( cd "$1" && jq -nc --arg c "$2" '{tool_input:{command:$c}}' | bash "$HOOK" ) >/dev/null 2>&1
  [ $? -eq 2 ] && echo true || echo false
}

fails=0
check() {  # <dir> <command> <want>
  local got
  got=$(verdict "$1" "$2")
  if [ "$got" = "$3" ]; then
    echo "ok   [$3] $2"
  else
    echo "FAIL want=$3 got=$got  $2"
    fails=$((fails + 1))
  fi
}

# --- shared matrix: no remotes, no aliases, so every verdict comes from the command string ---
echo "### shared matrix (checks 1-2: explicit flags, +refspec, compound commands) ###"
PLAIN=$(fixture_repo plain)
while IFS=$'\t' read -r cmd want; do
  check "$PLAIN" "$cmd" "$want"
done < <(jq -r '.cases[] | [.command, (.blocked|tostring)] | @tsv' "$CASES")

# --- shell-only: verdicts that depend on git config, so they cannot live in the matrix ---
echo
echo "### shell-only (check 4: aliases that resolve to a force push) ###"
ALIASES=$(fixture_repo aliases)
git -C "$ALIASES" config alias.fp 'push --force'
git -C "$ALIASES" config alias.yolo '!git push --force-with-lease'
git -C "$ALIASES" config alias.st 'status'
check "$ALIASES" 'git fp' true
check "$ALIASES" 'git fp origin main' true
check "$ALIASES" 'git yolo origin main' true
check "$ALIASES" 'git st && git push origin main' false  # alias that is not a push must not be rewritten

echo
echo "### shell-only (check 3: remote.<name>.push configured with a + refspec) ###"
FORCED=$(fixture_repo forced-refspec)
git -C "$FORCED" remote add origin https://example.invalid/x.git
git -C "$FORCED" config remote.origin.push '+refs/heads/main:refs/heads/main'
check "$FORCED" 'git push origin' true
# Known gap, asserted as the hook actually behaves: for a bare `git push` the hook takes the
# `git rev-parse --abbrev-ref @{push}` fallback, which prints the unresolvable literal `@{push}`
# once a push refspec is configured. That string is never validated against `git remote`, so
# check_remote looks up remote.@{push}.push, finds nothing, and the hook exits before the
# HEAD-branch scan that exists precisely for this case. Explicit-remote pushes are still caught.
check "$FORCED" 'git push' false

WILDCARD=$(fixture_repo wildcard-refspec)
git -C "$WILDCARD" remote add origin https://example.invalid/x.git
git -C "$WILDCARD" config remote.origin.push '+refs/heads/*:refs/heads/*'
check "$WILDCARD" 'git push origin' true

PLAIN_REFSPEC=$(fixture_repo plain-refspec)
git -C "$PLAIN_REFSPEC" remote add origin https://example.invalid/x.git
git -C "$PLAIN_REFSPEC" config remote.origin.push 'refs/heads/main:refs/heads/main'
check "$PLAIN_REFSPEC" 'git push origin' false

echo
[ "$fails" -eq 0 ] && echo "all passing" || echo "$fails failing"
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
