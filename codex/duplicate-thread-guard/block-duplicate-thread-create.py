#!/usr/bin/env python3
"""Hold an accepted Codex create_thread as live until it demonstrably fails.

create_thread is non-blocking. A task whose setup is still running returns only
`clientThreadId`, and while setup runs `list_threads` omits it; the entry it
returns afterwards can carry a null title, a null `projectId`, and a cwd under
`~/.codex/worktrees/<id>/base`. An agent that reads that silence as failure
re-creates the task. Every accepted create is a real worker that runs, opens a
PR, and consumes a worktree, so a re-create ships duplicate work.

This gate denies a create_thread that names a task another create already holds
in this session. Creates for any other task pass untouched.

A reservation is released only when the create itself fails, or when it ages out
of the window below. A task showing up in `list_threads` does not release it: a
visible running task is exactly the task a replacement would duplicate.

Codex only. It reads the app's own create_thread tool, which no other harness
exposes. Wire it once per event, and match the tool exactly:

    block-duplicate-thread-create.py --event pre     # PreToolUse
    block-duplicate-thread-create.py --event post    # PostToolUse

The event comes from argv rather than the payload so the script never guesses
which hook invoked it.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import sys
import time

# An accepted create is live and does not expire on its own. This window bounds
# how long the gate speaks for it, so a session cannot be blocked indefinitely
# by a reservation it can no longer reconcile.
TTL_SECONDS = 600

CREATE_TOOL = 'create_thread'

# The task's own issue or PR, which is the first GitHub reference in a task
# prompt. Later references are context the task reads, not the task itself.
GITHUB_REF = re.compile(r'https?://github\.com/([\w.-]+)/([\w.-]+)/(?:issues|pull)/(\d+)')


def state_dir() -> str:
    home = os.environ.get('CODEX_HOME') or os.path.expanduser('~/.codex')
    directory = os.path.join(home, 'tmp', 'thread-create-reservations')
    os.makedirs(directory, exist_ok=True)
    return directory


def state_path(session_id: str) -> str:
    safe = re.sub(r'[^A-Za-z0-9._-]', '_', session_id)[:120] or 'unknown'
    return os.path.join(state_dir(), f'{safe}.json')


def read_state(handle) -> dict[str, dict[str, object]]:
    handle.seek(0)
    try:
        state = json.loads(handle.read() or '{}')
    except ValueError:
        return {}
    if not isinstance(state, dict):
        return {}
    now = time.time()
    return {
        key: value
        for key, value in state.items()
        if isinstance(value, dict) and now - float(value.get('at') or 0) < TTL_SECONDS
    }


def write_state(handle, state: dict[str, dict[str, object]]) -> None:
    handle.seek(0)
    handle.truncate()
    handle.write(json.dumps(state))
    handle.flush()


def digest(kind: str, value: str) -> str:
    return f'{kind}:{hashlib.sha1(value.encode()).hexdigest()[:16]}'


def task_keys(tool_input: dict[str, object]) -> list[str]:
    """Every name this create claims. A create is a duplicate if it claims any held name."""
    keys = []

    match = GITHUB_REF.search(str(tool_input.get('prompt') or ''))
    if match:
        owner, repo, number = match.groups()
        keys.append(digest('ref', f'{owner.casefold()}/{repo.casefold()}#{number}'))

    title = ' '.join(str(tool_input.get('title') or '').split()).casefold()
    if title:
        target = tool_input.get('target')
        target = target if isinstance(target, dict) else {}
        # The environment is deliberately absent: the same task moved between a
        # worktree and a local checkout is still the same task.
        project = str(target.get('projectId') or target.get('type') or '')
        keys.append(digest('title', f'{project}\x00{title}'))

    return keys


def find_key(value: object, key: str) -> str | None:
    """First value for `key` anywhere in a nested response, JSON strings included."""
    if isinstance(value, dict):
        if isinstance(value.get(key), str):
            return value[key]
        for nested in value.values():
            found = find_key(nested, key)
            if found:
                return found
    elif isinstance(value, list):
        for nested in value:
            found = find_key(nested, key)
            if found:
                return found
    elif isinstance(value, str):
        try:
            return find_key(json.loads(value), key)
        except ValueError:
            match = re.search(rf'"{key}"\s*:\s*"([^"]+)"', value)
            if match:
                return match.group(1)
    return None


def deny(reservation: dict[str, object], title: object) -> None:
    age = int(time.time() - float(reservation.get('at') or 0))
    held = reservation.get('clientThreadId') or reservation.get('threadId') or 'setup in flight'
    reason = (
        f'Blocked: this session already created a task for "{title}" '
        f'({held}, accepted {age}s ago).\n'
        '\n'
        'An accepted create_thread stays live. A response carrying only '
        'clientThreadId means setup is still running, not that creation failed. '
        'While setup runs list_threads omits the task, and the entry it returns '
        'afterwards can carry a null title, a null projectId, and a cwd under '
        '~/.codex/worktrees/<id>/base. Absence from list_threads is not failure.\n'
        '\n'
        'Reconcile the task you already have:\n'
        '- call list_threads and match on recency and cwd, never on title or projectId\n'
        '- call read_thread or wait_threads on any thread you cannot account for\n'
        '- count workers from your own accepted create_thread responses\n'
        '\n'
        'Create a replacement only after a terminal failure or an explicit '
        'cancellation. If the task stays unaccounted for, report that instead of '
        'creating another. To run a second worker on this task deliberately, give '
        'it a title that distinguishes it from the first.'
    )
    print(
        json.dumps(
            {
                'hookSpecificOutput': {
                    'hookEventName': 'PreToolUse',
                    'permissionDecision': 'deny',
                    'permissionDecisionReason': reason,
                }
            }
        )
    )
    sys.exit(0)


def main() -> None:
    event = 'pre'
    if '--event' in sys.argv:
        event = sys.argv[sys.argv.index('--event') + 1]

    payload = json.load(sys.stdin)
    tool_name = str(payload.get('tool_name') or payload.get('toolName') or '')
    if not tool_name.endswith(CREATE_TOOL):
        return

    tool_input = payload.get('tool_input') or payload.get('toolInput') or {}
    if not isinstance(tool_input, dict):
        tool_input = {}
    keys = task_keys(tool_input)
    if not keys:
        return

    session_id = str(payload.get('session_id') or payload.get('sessionId') or 'unknown')
    path = state_path(session_id)

    # One lock across read, decide, and write. Two creates issued in the same
    # batch reach this hook concurrently; without the lock both would read an
    # empty state and both would pass.
    # O_RDWR rather than append mode: write_state rewinds and truncates, and an
    # appending descriptor would ignore the rewind.
    with os.fdopen(os.open(path, os.O_RDWR | os.O_CREAT, 0o600), 'r+') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        state = read_state(handle)

        if event == 'pre':
            for key in keys:
                if key in state:
                    write_state(handle, state)
                    deny(state[key], tool_input.get('title'))
            reservation = {'at': time.time()}
            for key in keys:
                state[key] = reservation
            write_state(handle, state)
            return

        response = payload.get('tool_response')
        if response is None:
            response = payload.get('toolResponse') or payload.get('tool_output') or ''
        thread_id = find_key(response, 'threadId')
        client_thread_id = find_key(response, 'clientThreadId')

        if thread_id or client_thread_id:
            reservation = {'at': time.time()}
            if thread_id:
                reservation['threadId'] = thread_id
            if client_thread_id:
                reservation['clientThreadId'] = client_thread_id
            for key in keys:
                state[key] = reservation
        else:
            # The create did not produce a task. Release the name it reserved.
            for key in keys:
                state.pop(key, None)
        write_state(handle, state)


if __name__ == '__main__':
    try:
        main()
    except Exception:
        # A gate that crashes a tool call is worse than a gate that misses one.
        pass
