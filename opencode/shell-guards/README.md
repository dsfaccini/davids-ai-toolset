# shell-guards for opencode2

Runs the [shell-guards](../../claude-code/plugins/shell-guards) before every opencode2 `shell` call and denies the call when a guard does. The guards themselves live in the Claude Code plugin; this plugin hands them the command and the directory it will run in, which is the call's `workdir` when it sets one.

Written for opencode2's plugin API: a default export of `{ id, setup }` that hooks `execute.before`. It does not implement opencode v1's plugin API.

Requires `bash`, `jq`, `git` and `python3` on `PATH`.

## Install

Clone this repo somewhere permanent, then link the plugin into opencode's plugin folder:

```sh
git clone https://github.com/dsfaccini/davids-ai-toolset
ln -s /path/to/davids-ai-toolset/opencode/shell-guards/shell-guards.ts ~/.config/opencode/plugin/shell-guards.ts
```

The plugin follows the link back to the clone to find the guards, so keep the clone in place.

## Develop

```sh
bun test opencode/shell-guards
```
