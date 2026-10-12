# shell-guards for pi

Runs the [shell-guards](../../claude-code/plugins/shell-guards) before every pi `bash` call and blocks the call when a guard denies it. The guards themselves live in the Claude Code plugin; this extension hands them the command and the session's working directory.

Requires `bash`, `jq`, `git` and `python3` on `PATH`.

## Install

Clone this repo somewhere permanent, then point pi at the extension file:

```sh
git clone https://github.com/dsfaccini/davids-ai-toolset
pi install /path/to/davids-ai-toolset/pi/shell-guards/shell-guards.ts
```

The extension finds the guards relative to its own location, so keep the clone in place.

## Develop

```sh
bun test pi/shell-guards
```
