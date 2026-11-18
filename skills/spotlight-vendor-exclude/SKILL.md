---
name: spotlight-vendor-exclude
description: Load when a Mac slows down during dependency installs or builds, when mds or mdworker_shared processes take CPU, or when asked to keep Spotlight out of node_modules, build output or package caches. Finds dependency, cache and build-output folders that hold thousands of files and adds them to Spotlight's privacy list, so source folders stay searchable. Skip on Linux and Windows, and skip when the user wants every code folder out of Spotlight, which the privacy list in System Settings does in one step.
---

# Spotlight vendor exclude

## Purpose

Keep Spotlight from indexing the folders that package managers and build tools fill with thousands of files. Source code, documents and apps stay indexed.

Spotlight imports every new file it can see. Measured on macOS 27.2 during parallel dependency installs: Spotlight indexed about 55,000 files in 30 minutes. About 37,000 were under `node_modules`, about 18,000 under `dist`, and about 12,000 in the pnpm store.

## What Spotlight skips without help

Measured on macOS 27.2:

- Spotlight skips a folder whose name starts with a dot: `.venv`, `.git`, `.wrangler`, `~/.cargo`, `~/.rustup`, `~/.npm`, `~/.bun`.
- Spotlight skips a folder whose name ends in `.noindex`.
- Spotlight ignores an empty `.metadata_never_index` file inside a folder. Do not rely on that file.

## What the script excludes

`scripts/spotlight-vendor-exclude` walks each root, which defaults to the user's home. It skips dot-folders and `~/Library`. It stays on the root's filesystem. A folder qualifies when it holds at least `MIN_FILES` files (default 1000) and matches one rule:

- Its name is `node_modules`, `bower_components` or `Pods`.
- It holds `pyvenv.cfg` (a Python virtualenv) or `CACHEDIR.TAG` (a cache, such as a Cargo `target`).
- It is a Go `vendor` folder that holds `modules.txt`.
- Its name is `target`, `dist`, `build`, `out`, `coverage` or `vendor`, and git ignores it.
- It is a package cache under the root: `Library/pnpm/store`, `go/pkg/mod` or `Library/Developer/Xcode/DerivedData`.

The script writes the privacy list in `/System/Volumes/Data/.Spotlight-V100/VolumeConfiguration.plist`, then restarts `mds`. It records the entries it added. It removes only those entries, and only after their folder is gone.

## Steps

1. Confirm that Spotlight is busy: `ps -Ao pcpu,comm -r | grep -E 'mds|mdworker' | head`.
2. Preview the folders: `scripts/spotlight-vendor-exclude list`. The list needs no root.
3. Ask the user to run `sudo <skill folder>/scripts/spotlight-vendor-exclude install` in a terminal app that has Full Disk Access. The command needs root. `install` applies the list now and installs a LaunchDaemon that repeats it every hour, which catches folders from new checkouts and installs. When the user wants no LaunchDaemon, ask them to run `apply` instead of `install`.
4. Verify on one listed folder: `mdfind -count -onlyin <folder> 'kMDItemDisplayName == "*"'`. Done means the count is 0 a few minutes after the run.

## Undo

`sudo <skill folder>/scripts/spotlight-vendor-exclude uninstall` removes the LaunchDaemon and every entry the script added. Entries the user added by hand stay.
