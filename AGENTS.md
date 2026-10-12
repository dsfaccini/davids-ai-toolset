# davids-ai-toolset

This repo is public. Keep secrets, absolute home paths and private context out of every file.

## Where each item goes

- Put a harness-agnostic skill in `skills/<name>/SKILL.md`. `npx skills add` discovers skills there.
- Put a Claude Code plugin (mod, hooks, commands, subagents) in `claude-code/plugins/<name>/`.
- List each Claude Code plugin in `.claude-plugin/marketplace.json`, with `source` set to `./claude-code/plugins/<name>`.
- Put an extension for one other harness in `<harness>/<name>/`, named after the harness (`codex`, `pi`, `opencode`).
- Add each new item to the index in `README.md`, with a one-line description.

## Done means

- The item has its own README with its install line.
- The item ships tests, and they pass.
- A Claude Code plugin passes `claude plugin validate <plugin folder>` and `claude plugin test <plugin folder>`.
- After a change to `.claude-plugin/marketplace.json`, `claude plugin validate .` passes at the repo root.
