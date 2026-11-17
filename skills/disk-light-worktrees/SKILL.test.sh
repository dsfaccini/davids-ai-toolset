#!/usr/bin/env bash
# Structure and publication checks for the disk-light-worktrees skill.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL="$DIR/SKILL.md"
fails=0

check() { # <label> <command...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok   $label"; else echo "FAIL $label"; fails=$((fails + 1)); fi
}
absent() { # <label> <extended regex> <file...>
  local label="$1" re="$2"; shift 2
  if grep -n -i -E -e "$re" "$@" >/dev/null 2>&1; then
    echo "FAIL $label"; grep -n -i -E -e "$re" "$@"; fails=$((fails + 1))
  else echo "ok   $label"; fi
}

front=$(awk 'NR==1&&$0!="---"{exit} NR>1&&$0=="---"{exit} NR>1{print}' "$SKILL")
name=$(printf '%s\n' "$front" | sed -n 's/^name: *//p')
desc=$(printf '%s\n' "$front" | sed -n 's/^description: *//p')

check "name matches the folder" test "$name" = "$(basename "$DIR")"
check "description is set" test -n "$desc"
check "description says when to load" grep -qi 'before creating a git worktree' <<<"$desc"
check "description says when to skip" grep -qi 'skip' <<<"$desc"

# The shell blocks must parse, and the checks below read them, not the prose.
blocks=$(mktemp); joined=$(mktemp); trap 'rm -f "$blocks" "$joined"' EXIT
awk '/^```sh$/{on=1;next} /^```$/{on=0} on' "$SKILL" >"$blocks"
check "shell blocks parse" bash -n "$blocks"
sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$blocks" >"$joined"

# Every command the skill relies on, as text of its shell blocks.
for cmd in 'artifact-fs add-repo' 'artifact-fs daemon' 'artifact-fs status' 'artifact-fs list-repos' \
  'artifact-fs evict-cache' '--adopt-gitdir' '--blob-cache-dir' '--mount-root' 'worktree add --no-checkout' \
  'worktree lock' 'worktree unlock' 'worktree remove' 'read-tree HEAD' 'go build'; do
  check "block runs $cmd" grep -qF -e "$cmd" "$blocks"
done

# Every --flag on an artifact-fs line must be one the CLI defines (internal/cli/cli.go of the fork).
known=' --name --remote --branch --ref --require-commit --depth --refresh --mount-root --async --adopt-gitdir
 --prepared-gitdir --git-dir --blob-cache-dir --fetch-ref --warn-kept-generations --root
 --hydration-concurrency --max-bytes --older-than --help '
bad=""
while read -r flag; do
  case " $(echo $known) " in *" $flag "*) ;; *) bad="$bad $flag";; esac
done < <(grep -E 'artifact-fs +(add-repo|daemon|status|list-repos|evict-cache|remove-repo|unmount|remount|prepare|fetch)' "$joined" | grep -oE ' --[a-z][a-z-]*' | tr -d ' ' | sort -u)
if [ -z "$bad" ]; then echo "ok   artifact-fs flags are defined by the CLI"; else echo "FAIL unknown artifact-fs flags:$bad"; fails=$((fails + 1)); fi

# Public repo: no private paths, no secrets, no security material.
absent "no absolute home paths" '/(Users|home)/[A-Za-z0-9._-]+' "$SKILL" "$DIR/README.md"
absent "no secrets" '(ghp_|github_pat_|sk-[A-Za-z0-9]{10,}|api[_-]?key|password *=|token *=)' "$SKILL" "$DIR/README.md"
absent "no security material" 'vuln''erab|embar''go|\bCVE-|exploit|advis''ory' "$SKILL" "$DIR/README.md"

[ "$fails" -eq 0 ] && echo "all checks passed" || { echo "$fails check(s) failed"; exit 1; }
