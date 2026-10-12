# davids-ai-toolset

Skills, Claude Code plugins and extensions for other AI coding assistants.

## Layout

| Path | Holds | Install |
| --- | --- | --- |
| `skills/<name>/` | Agent Skills (`SKILL.md`), for any harness that reads them | `npx skills add dsfaccini/davids-ai-toolset` |
| `claude-code/plugins/<name>/` | Claude Code plugins: mods, hooks, commands, subagents | `/plugin install <name> --marketplace dsfaccini/davids-ai-toolset` |
| `<harness>/<name>/` | Extensions for one other harness (`codex`, `pi`, `opencode`, ...) | See the item's README |

## Index

### Claude Code plugins

- [last-message-time](claude-code/plugins/last-message-time): shows when the last message was sent, after a resume or a long idle.
