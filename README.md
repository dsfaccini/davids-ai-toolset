# davids-ai-toolset

Skills, Claude Code plugins and extensions for other AI coding assistants.

## Layout

| Path | Holds | Install |
| --- | --- | --- |
| `skills/<name>/` | Agent Skills (`SKILL.md`), for any harness that reads them | `npx skills add dsfaccini/davids-ai-toolset` |
| `claude-code/plugins/<name>/` | Claude Code plugins: mods, hooks, commands, subagents. Code that several harnesses share lives here too | `/plugin install <name> --marketplace dsfaccini/davids-ai-toolset` |
| `<harness>/<name>/` | Extensions and hooks for one other harness (`codex`, `pi`, `opencode`, ...), which may run code from a Claude Code plugin | See the item's README |

## Index

### Claude Code plugins

- [last-message-time](claude-code/plugins/last-message-time): shows when the last message was sent, after a resume or a long idle.
- [shell-guards](claude-code/plugins/shell-guards): blocks force pushes, busy-wait loops, broad process kills, unapproved recursive deletes, and whole-suite test and type-check runs in pydantic-ai. Also installs into Grok Build, Codex and mastracode.

### pi extensions

- [shell-guards](pi/shell-guards): runs shell-guards before every pi `bash` call.

### opencode plugins

- [shell-guards](opencode/shell-guards): runs shell-guards before every opencode2 `shell` call.

### Codex hooks

- [duplicate-thread-guard](codex/duplicate-thread-guard): stops an agent from creating the same Codex app task twice.
