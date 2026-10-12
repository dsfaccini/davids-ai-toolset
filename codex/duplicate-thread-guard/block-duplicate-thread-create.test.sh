#!/usr/bin/env bash
# Regression matrix for block-duplicate-thread-create.py.
# Covers the shape that produced duplicate workers: a create accepted with only a
# clientThreadId, a list_threads view that does not show it, and a second create
# for the same task.
set -u
HOOK="$(cd "$(dirname "$0")" && pwd)/block-duplicate-thread-create.py"
CODEX_HOME=$(mktemp -d)
export CODEX_HOME
trap 'rm -rf "$CODEX_HOME"' EXIT

SID=session-under-test
PROJ_A=project-a
PROJ_B=project-b
ISSUE_A=https://github.com/acme/api/issues/11
ISSUE_B=https://github.com/acme/web/issues/22
TITLE_A="Support path prefixes"
TITLE_B="Serve the bundle under a prefix"
fails=0

payload() { # <title> <projectId> <prompt> [environment]
  jq -nc --arg s "$SID" --arg t "$1" --arg p "$2" --arg m "$3" --arg e "${4:-worktree}" \
    '{session_id:$s,tool_name:"codex_app__create_thread",
      tool_input:{title:$t,prompt:$m,target:{type:"project",projectId:$p,environment:{type:$e}}}}'
}

decision() { printf '%s' "$1" | jq -r 'try .hookSpecificOutput.permissionDecision catch ""'; }

pre() { # <label> <deny|allow> <title> <projectId> <prompt> [environment]
  local out got=allow
  out=$(payload "$3" "$4" "$5" "${6:-worktree}" | python3 "$HOOK" --event pre)
  [ "$(decision "$out")" = deny ] && got=deny
  if [ "$got" = "$2" ]; then echo "ok   [$2] $1"; else echo "FAIL want=$2 got=$got  $1"; fails=$((fails + 1)); fi
}

post() { # <title> <projectId> <prompt> <response>
  payload "$1" "$2" "$3" | jq -c --arg r "$4" '. + {tool_response:$r}' | python3 "$HOOK" --event post
}

PENDING='{"clientThreadId":"client-new-thread:0000","hostId":"local"}'
READY='{"threadId":"0199aaaa-bbbb-7ccc-8ddd-eeeeffff0000","hostId":"local"}'
REJECTED='create_thread received invalid arguments'

pre "first create for task A"                 allow "$TITLE_A" "$PROJ_A" "Implement $ISSUE_A"
post "$TITLE_A" "$PROJ_A" "Implement $ISSUE_A" "$PENDING"
pre "second create, same issue and title"     deny  "$TITLE_A" "$PROJ_A" "Implement $ISSUE_A"
pre "same issue, reworded title"              deny  "Handle prefixes" "$PROJ_A" "Implement $ISSUE_A"
pre "same title, prompt without an issue"     deny  "$TITLE_A" "$PROJ_A" "Wait for the implementation prompt."
pre "same task moved to a local environment"  deny  "$TITLE_A" "$PROJ_A" "Wait for the handoff." local

pre "a different task in the same project"    allow "Fix the flaky import test" "$PROJ_A" "Fix the flaky test"
pre "a different task in another project"     allow "$TITLE_B" "$PROJ_B" "Implement $ISSUE_B"
post "$TITLE_B" "$PROJ_B" "Implement $ISSUE_B" "$PENDING"
pre "task B is now held too"                  deny  "$TITLE_B" "$PROJ_B" "Implement $ISSUE_B"

# A create that returns a ready threadId is just as live as a pending one.
pre "first create for task C"                 allow "Bump the pinned version" "$PROJ_A" "Bump it"
post "Bump the pinned version" "$PROJ_A" "Bump it" "$READY"
pre "second create after a ready threadId"    deny  "Bump the pinned version" "$PROJ_A" "Bump it"

# A create that produced no task releases the name it reserved.
pre "first create for task D"                 allow "Rotate the cache key" "$PROJ_A" "Rotate it"
post "Rotate the cache key" "$PROJ_A" "Rotate it" "$REJECTED"
pre "retry after a rejected create"           allow "Rotate the cache key" "$PROJ_A" "Rotate it"

# Concurrency: identical creates issued in one batch must not both pass.
CONC_TITLE="Batch race task"
CONC_PROMPT="Implement https://github.com/acme/api/issues/99"
for _ in 1 2 3 4; do
  payload "$CONC_TITLE" "$PROJ_A" "$CONC_PROMPT" | python3 "$HOOK" --event pre > "$CODEX_HOME/race.$$.$RANDOM.out" &
done
wait
allowed=$(for f in "$CODEX_HOME"/race.*.out; do grep -q deny "$f" || echo x; done | wc -l | tr -d ' ')
if [ "$allowed" = 1 ]; then echo "ok   [deny] only one of four concurrent identical creates passes"; else
  echo "FAIL want=1 passed=$allowed  concurrent identical creates"; fails=$((fails + 1)); fi

# Reservations are per session.
out=$(payload "$TITLE_A" "$PROJ_A" "Implement $ISSUE_A" | jq -c '.session_id = "another-session"' | python3 "$HOOK" --event pre)
if [ -z "$out" ]; then echo "ok   [allow] the same task in another session"; else
  echo "FAIL want=allow got=deny  the same task in another session"; fails=$((fails + 1)); fi

# Tools this gate does not own pass untouched.
out=$(jq -nc --arg s "$SID" '{session_id:$s,tool_name:"exec_command",tool_input:{cmd:"git status"}}' | python3 "$HOOK" --event pre)
if [ -z "$out" ]; then echo "ok   [allow] a tool this gate does not own"; else
  echo "FAIL want=allow got=deny  a tool this gate does not own"; fails=$((fails + 1)); fi

# A listing that shows the task must not release it.
jq -nc --arg s "$SID" '{session_id:$s,tool_name:"codex_app__list_threads",tool_response:"[{\"id\":\"0199aaaa\",\"title\":\"Support path prefixes\"}]"}' \
  | python3 "$HOOK" --event post
pre "task A still held after it appears in a listing" deny "$TITLE_A" "$PROJ_A" "Implement $ISSUE_A"

echo
[ "$fails" -eq 0 ] && echo "all passing" || echo "$fails failing"
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
