# duplicate-thread-guard

A Codex hook that stops an agent from creating the same task twice with the Codex app's `create_thread` tool.

`create_thread` returns before the task's setup finishes. While setup runs, `list_threads` leaves the task out, and an agent that reads that silence as failure creates the task again. Each accepted create is a real worker, so the second one ships duplicate work.

The guard records every accepted create per session, keyed by the first GitHub issue or PR URL in its prompt and by its title within its project. A later create that matches a held task is denied with instructions to reconcile the running task instead. A reservation is released when the create itself fails, or after 10 minutes. To run a second worker on purpose, give it a distinct title.

Requires `python3`. Reservations live in `$CODEX_HOME/tmp/thread-create-reservations/` (`~/.codex` when `CODEX_HOME` is unset).

## Install

Clone this repo somewhere permanent:

```sh
git clone https://github.com/dsfaccini/davids-ai-toolset
```

Then add both hooks to `~/.codex/config.toml`, replacing `/path/to/davids-ai-toolset` with the clone's absolute path:

```toml
[features]
hooks = true

[[hooks.PreToolUse]]
matcher = "codex_app__create_thread"

[[hooks.PreToolUse.hooks]]
type = "command"
command = "python3 /path/to/davids-ai-toolset/codex/duplicate-thread-guard/block-duplicate-thread-create.py --event pre"
timeout = 10
statusMessage = "Checking for an unresolved task setup"

[[hooks.PostToolUse]]
matcher = "codex_app__create_thread"

[[hooks.PostToolUse.hooks]]
type = "command"
command = "python3 /path/to/davids-ai-toolset/codex/duplicate-thread-guard/block-duplicate-thread-create.py --event post"
timeout = 10
statusMessage = "Recording task setup state"
```

## Develop

```sh
bash codex/duplicate-thread-guard/block-duplicate-thread-create.test.sh
```
