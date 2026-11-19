# spotlight-vendor-exclude

Keeps macOS Spotlight out of `node_modules`, build output and package caches, so dependency installs stop feeding thousands of files to the indexer. Source folders stay searchable.

Measured on macOS 27.2 during parallel dependency installs: Spotlight indexed about 55,000 files in 30 minutes, about 37,000 of them under `node_modules`. After one `apply`, the excluded folders dropped to 0 indexed files within two minutes; the pnpm store alone went from 524,296. Source folders kept their entries.

Spotlight's privacy list takes exact paths, not patterns. The script finds the folders and keeps the list in sync. A folder qualifies when it holds at least 1000 files (`MIN_FILES`) and matches one of these:

- `node_modules`, `bower_components` or `Pods`
- a Python virtualenv (`pyvenv.cfg`) or a tagged cache (`CACHEDIR.TAG`, for example a Cargo `target`)
- `target`, `dist`, `build`, `out`, `coverage` or `vendor`, when git ignores it
- the pnpm store, the Go module cache or Xcode's DerivedData

Spotlight already skips dot-folders such as `.venv` and `.cargo`, so the script leaves them out.

## Keep new installs out of Spotlight

Spotlight skips dot-folders, so a package manager that stores files in one needs no exclusion:

- pnpm already keeps package files in `node_modules/.pnpm`.
- bun does the same with `linker = "isolated"` under `[install]` in `~/.bunfig.toml`: files go to `node_modules/.bun`. Code that imports a package it never declared breaks under this layout; declare the package. A project that must keep the flat layout sets `linker = "hoisted"` under `[install]` in its own `bunfig.toml`, then runs `bun install`; bun ignores the key anywhere else.
- npm's `install-strategy=linked` hides the files too, but on npm 12.2.2 it failed parallel installs in one checkout and rewrote lockfiles of packages with bundled dependencies. Leave npm on hoisted and exclude its folders with `apply`.

## Use

```sh
scripts/spotlight-vendor-exclude list          # preview, no root needed
sudo scripts/spotlight-vendor-exclude apply    # add the folders to Spotlight's privacy list
sudo scripts/spotlight-vendor-exclude remove   # remove every entry it added
```

Run the `sudo` commands in a terminal app that has Full Disk Access. Pass folders after the command to scan those instead of your home. Re-run `apply` after new checkouts and installs: it adds new folders and drops entries whose folder is gone. It cannot run on a schedule, because macOS keeps a LaunchDaemon without Full Disk Access out of the privacy list.

## Install as an agent skill

```sh
npx skills add dsfaccini/davids-ai-toolset --skill spotlight-vendor-exclude
```

Or copy the `skills/spotlight-vendor-exclude` folder into the harness's skills directory:

| Harness | Skills directory |
| --- | --- |
| Claude Code | `~/.claude/skills/` |
| Codex | `~/.agents/skills/` |
| pi | `~/.agents/skills/` |
| opencode | `~/.agents/skills/` |

## Develop

```sh
bash skills/spotlight-vendor-exclude/spotlight-vendor-exclude.test.sh
```

The test checks the skill's frontmatter and that the folder rules find exactly the expected folders in a fixture tree. On macOS it also syncs a scratch plist: adding, re-running, dropping a deleted folder, and removing. CI runs every `*.test.sh` in the repo.
