# davids-ai-toolset

This repo is public. Keep secrets, absolute home paths and private context out of every file.

## Where each item goes

- Put a harness-agnostic skill in `skills/<name>/SKILL.md`. `npx skills add` discovers skills there.
- Put a Claude Code plugin (mod, hooks, commands, subagents) in `claude-code/plugins/<name>/`.
- List each Claude Code plugin in `.claude-plugin/marketplace.json`, with `source` set to `./claude-code/plugins/<name>`.
- Put an extension for one other harness in `<harness>/<name>/`, named after the harness (`codex`, `pi`, `opencode`).
- Keep one copy of code that several harnesses run. Put it in the Claude Code plugin, and reference it from `<harness>/<name>/` by relative path. A marketplace install copies only the plugin folder, so the plugin cannot reach files outside it.
- Add each new item to the index in `README.md`, with a one-line description.

## Done means

- Each item folder has its own README with an install line for each harness it supports.
- The item ships tests, and they pass.
- A Claude Code plugin passes `claude plugin validate <plugin folder>`.
- A Claude Code plugin with a hooks module (a mod) also passes `claude plugin test <plugin folder>`.
- After a change to `.claude-plugin/marketplace.json`, `claude plugin validate .` passes at the repo root.
