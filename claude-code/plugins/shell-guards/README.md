# shell-guards

Hooks that stop an agent's shell command before it does outsized damage. Each guard tells the agent why it was blocked and what to run instead.

| Guard | Blocks | Where |
| --- | --- | --- |
| `block-force-push.sh` | `git push --force`, `-f`, `--force-with-lease`, `--force-if-includes`, `--mirror`, `+refspec`, a `+` refspec configured in `remote.<name>.push`, and git aliases that expand to any of these | everywhere |
| `block-busy-loop.sh` | `while`/`until` loops that spin a CPU core with no `sleep` or `wait` | everywhere |
| `block-broad-pkill.sh` | `pkill -f`, `killall -m`, an option after the pattern, and `pgrep` output fed to `kill` under the same rules | everywhere |
| `disallow-recursive-delete.py` | `rm -r`/`-R`/`--recursive` unless every target resolves strictly inside an approved root | everywhere |
| `block-heavy-tests.sh` | `make test`/`testcov`/`test-all-python`/`all`, `tox`, `nox`, pytest with xdist or `--cov`, untargeted `coverage run` | pydantic-ai and pydantic-ai-harness worktrees |
| `block-broad-typecheck.sh` | `make typecheck*` and `pyright` with no target files | pydantic-ai and pydantic-ai-harness worktrees |

The two pydantic-ai guards find their repo by remote URL, so they cover every clone, fork and worktree and stay silent everywhere else.

Every harness calls one entry point, `hooks/run-guards.sh`, which runs the guards in order and passes on the first deny.

## Requirements

`bash`, `jq` and `git` on `PATH`, plus `python3` for the recursive-delete guard. macOS or Linux.

## Configure

The recursive-delete guard approves the system temporary directories. Add your own roots to `RECURSIVE_DELETE_ROOTS`, separated like `PATH`, in the environment that launches the harness:

```sh
export RECURSIVE_DELETE_ROOTS="$HOME/projects:$HOME/scratch"
```

A target equal to a root, your home directory, or `/` is never approved.

## Install

### Claude Code

```
/plugin install shell-guards --marketplace dsfaccini/davids-ai-toolset
```

### Grok Build

Grok reads this repo's Claude Code marketplace:

```sh
grok plugin marketplace add dsfaccini/davids-ai-toolset
grok plugin install shell-guards --trust
```

### pi, opencode2, Codex, mastracode

These harnesses run the guards from a clone of this repo. Clone it somewhere permanent:

```sh
git clone https://github.com/dsfaccini/davids-ai-toolset
```

Below, replace `/path/to/davids-ai-toolset` with the clone's absolute path.

**pi**, through the [pi adapter](../../../pi/shell-guards):

```sh
pi install /path/to/davids-ai-toolset/pi/shell-guards/shell-guards.ts
```

**opencode2**, through the [opencode adapter](../../../opencode/shell-guards):

```sh
ln -s /path/to/davids-ai-toolset/opencode/shell-guards/shell-guards.ts ~/.config/opencode/plugin/shell-guards.ts
```

**Codex**, in `~/.codex/config.toml`:

```toml
[features]
hooks = true

[[hooks.PreToolUse]]
matcher = "Bash"

[[hooks.PreToolUse.hooks]]
type = "command"
command = "bash /path/to/davids-ai-toolset/claude-code/plugins/shell-guards/hooks/run-guards.sh --protocol codex"
timeout = 10
statusMessage = "Checking shell guards"
```

**mastracode**, merged into `~/.mastracode/hooks.json` (or a project's `.mastracode/hooks.json`):

```json
{
  "PreToolUse": [
    {
      "type": "command",
      "command": "bash /path/to/davids-ai-toolset/claude-code/plugins/shell-guards/hooks/run-guards.sh",
      "description": "Refuse force pushes, busy-wait loops, broad process kills and unapproved recursive deletes",
      "matcher": { "tool_name": "execute_command" }
    }
  ]
}
```

To run only some guards, name their files after `run-guards.sh`, for example `run-guards.sh block-force-push.sh block-busy-loop.sh`.

## How it works

A guard reads the PreToolUse payload as JSON on stdin and finds the command under `tool_input.command`, `tool_input.cmd` (Codex) or `toolInput.command` (Grok). To deny, it writes the reason to stderr and `{"decision":"deny","reason":...}` to stdout, and exits 2. `--protocol codex` switches the deny to Codex's `hookSpecificOutput` JSON on stdout with exit 0. A guard that cannot run, for example because `jq` is missing, allows the command.

The guards answer git questions (aliases, configured refspecs, remote URLs) from the directory the hook runs in. The pi and opencode adapters run them in the command's working directory.

## Develop

Each guard has a case matrix (`*.cases.json`) and a runner (`*.test.sh`):

```sh
for t in hooks/*.test.sh; do bash "$t" || exit 1; done
claude plugin validate .
```
