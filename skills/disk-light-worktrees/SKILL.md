---
name: disk-light-worktrees
description: Load before creating a git worktree when disk space is a concern, such as many parallel worktrees of a large repository. Sets up worktrees with artifact-fs, which mounts a worktree lazily from a blobless clone with a shared blob cache. Covers installing artifact-fs, creating, checking and removing a worktree, and which files to symlink or copy into it. Skip on a reflink filesystem (APFS, Btrfs, XFS with reflink) when a copy-on-write worktree tool is available, for one or two worktrees, and when commands that walk the whole tree must stay fast.
---

# Disk-light worktrees

## Purpose

Create git worktrees that take a fraction of a normal checkout's disk. artifact-fs is a FUSE filesystem. It serves a worktree from the repository's git dir and fetches each file's contents on first read into one blob cache that every worktree shares.

Measured disk on a 16-core Linux box with ext4, pydantic-ai worktree, median of three runs, counting the checkout, its git dir and its virtualenv's private bytes, and leaving out the shared blob cache, which every worktree reuses:

- Fresh worktree: about 43 MiB through artifact-fs against about 371 MiB for `git worktree add`, about 88% less.
- After a test workload (ruff, pyright and pytest runs): about 160 MiB against 488 MiB, about 67% less.

## Outcome

A linked git worktree at a path you chose, mounted by its own artifact-fs daemon, that behaves like a normal worktree for `git` and file tools. Removal leaves no mount, daemon, state root or worktree registration behind, and the branch keeps its commits.

## When not to use

- On a reflink filesystem (APFS, Btrfs, XFS with reflink), use a copy-on-write worktree tool when one is available. It costs less per command.
- For one or two worktrees, `git worktree add` is simpler.
- Every command that walks the tree is slower through FUSE. Measured on a 16-core Linux box with ext4, `rg` over a worktree took 0.59 s through artifact-fs against 0.03 s on a native checkout, cold.

## Install artifact-fs

Run this section only when `command -v artifact-fs` finds nothing. No release binaries exist yet, so build from source. When release binaries exist, replace the steps in this section and leave the rest of the skill unchanged.

1. Check the prerequisites.
   - Linux: `fuse3` (`fusermount3` on `PATH`) and a readable and writable `/dev/fuse`.
   - macOS: 26 or newer, macFUSE 5.5 or newer. The FSKit backend needs no kernel extension. Ask the user to enable the `macFUSE` and `macFUSE (local)` file system extensions under System Settings > General > Login Items & Extensions > File System Extensions. Ask the user to grant the terminal app the Network Volumes permission under Privacy & Security > Files & Folders. Without it, opening files on a mount and `umount` fail with `Operation not permitted`.
2. Clone the fork:

```sh
git clone https://github.com/dsfaccini/artifact-fs "$HOME/.local/src/artifact-fs"
```

3. Install the Go version named in the `go` line of `go.mod` in that clone.
4. Build the CLI. The module path stays `github.com/cloudflare/artifact-fs`, so `go install` cannot fetch the fork. Build from the checkout:

```sh
cd "$HOME/.local/src/artifact-fs"
mkdir -p "$HOME/.local/bin"
GOWORK=off go build -o "$HOME/.local/bin/artifact-fs" ./cmd/artifact-fs
```

5. Put the bin directory on `PATH`, then run `artifact-fs --help`.

Git 2.45 or newer keeps size checks in blobless clones from fetching blobs one at a time. Older git still works, more slowly.

## Create a worktree

Your shell may not keep variables between commands. Save this block to a file and source it in every command below.

Set these variables once per worktree. `NAME` is the worktree directory's basename and the artifact-fs repo name.

```sh
SRC=/path/to/existing/checkout          # a normal clone of the repository
MOUNT_ROOT=/path/to/worktrees           # existing directory, outside $SRC
NAME=feature-x
BRANCH=feature-x
START=main                              # base for a new branch
WT="$MOUNT_ROOT/$NAME"
META="$HOME/.local/share/disk-light-worktrees/$NAME"
STATE="$META/state"                     # this worktree's artifact-fs state root
CACHE="$HOME/.local/share/disk-light-worktrees/blobs"   # shared by every worktree
```

Constraints:

- `$WT` must not exist. `$MOUNT_ROOT` must exist and lie outside `$SRC`.
- Give each worktree its own `$STATE`, so each has its own daemon. Share one `$CACHE`.
- Keep `$STATE` in your home directory, never under `/tmp`. artifact-fs refuses a state root that another user owns or can write.
- artifact-fs mounts a repo at `<mount-root>/<name>`, so `--mount-root "$MOUNT_ROOT"` and `--name "$NAME"` place the mount at `$WT`.

Steps. Order matters from the second command on:

```sh
mkdir -p "$META" "$CACHE"
git -C "$SRC" worktree add --no-checkout --no-track -b "$BRANCH" "$WT" "$START"
# for an existing branch: git -C "$SRC" worktree add --no-checkout "$WT" "$BRANCH"
GITDIR=$(git -C "$WT" rev-parse --absolute-git-dir)
git --git-dir="$GITDIR" read-tree HEAD
git -C "$SRC" worktree lock --reason 'artifact-fs worktree' "$WT"
mv "$WT/.git" "$META/gitfile"           # the mountpoint must be empty

ARTIFACT_FS_ROOT="$STATE" artifact-fs add-repo --name "$NAME" --adopt-gitdir \
  --git-dir "$GITDIR" --mount-root "$MOUNT_ROOT" --blob-cache-dir "$CACHE"

cd "$META"                              # never start the daemon from inside a mount
ARTIFACT_FS_ROOT="$STATE" nohup artifact-fs daemon >"$META/daemon.log" 2>&1 </dev/null &
echo $! >"$META/daemon.pid"
```

- `--adopt-gitdir` registers the worktree's git dir without cloning or fetching. It rejects `--remote`, `--ref`, `--branch`, `--depth`, `--async` and the other acquisition flags. It keeps remote refresh off, so run `git fetch` yourself.
- `add-repo` does not mount. The daemon mounts every repo registered on its state root.

Wait for the mount, at most 60 seconds:

```sh
for _ in $(seq 60); do
  ARTIFACT_FS_ROOT="$STATE" artifact-fs status --name "$NAME" | grep -q ' state=mounted ' && test -f "$WT/.git" && break
  sleep 1
done
test -f "$WT/.git" || { tail "$META/daemon.log"; echo "mount failed"; }
git -C "$WT" rev-parse --show-toplevel
```

Right after a restart that follows a crash, `status` can still report the dead daemon's last record (`state=mounted`) before the new mount serves. Only a live mount serves `$WT/.git`, because the create step moved the real gitfile away. On failure, read `$META/daemon.log`. Then deploy config into `$WT` as the next section says.

## Deploy config into a new worktree

Decide per file: does every worktree share it, or does the worktree change it?

- **Symlink** a file that every worktree shares and that no worktree writes: harness instruction files, shared skills, commands, hooks and shared settings. One source then updates every worktree.
- **Copy** per-worktree state: local settings files, env files, caches, notes, and anything a tool writes. A symlinked state file lets one worktree overwrite another's.
- Treat a file you cannot place as state. Copy it.
- Skip every path that git tracks in the worktree.
- Add each deployed path, such as `/AGENTS.md`, to the file that `git -C "$WT" rev-parse --git-path info/exclude` prints. Otherwise the worktree reports it as untracked, and step 2 of removal refuses. Git reads that file from the common git dir, so it applies to `$SRC` and to every worktree of it.
- On macOS, copy onto a mount with `cp -X`. The mount rejects extended attributes, and a plain `cp` can fail on them.
- Put generated dependency directories, such as a virtualenv or `node_modules`, on native disk and symlink them in. Each is state of one worktree, so give each worktree its own target.

## Check health

```sh
ARTIFACT_FS_ROOT="$STATE" artifact-fs status --name "$NAME"
ARTIFACT_FS_ROOT="$STATE" artifact-fs list-repos
```

- `state=mounted` means the mount serves. `degraded` means the FUSE mount is down. `unmounted`, `preparing` and `failed` mean it is not serving.
- `last_error`, `mount_error` and `next_retry` name the failure and the retry.
- `overlay_dirty=true` means the overlay holds written files. They can match HEAD, so check for uncommitted work with `git status`.
- `hydrated_blobs` and `hydrated_bytes` report the blob cache.
- Without a running daemon, `status` reports `unmounted`.
- `ARTIFACT_FS_ROOT` selects the state root. A command without it reads the default root and finds no repo.

Shrink the shared cache with `--older-than`, `--max-bytes`, or both. It never runs on its own.

```sh
ARTIFACT_FS_ROOT="$STATE" artifact-fs evict-cache --name "$NAME" --older-than 336h
# or: ... artifact-fs evict-cache --name "$NAME" --max-bytes <bytes>
```

## Remove a worktree

Never remove a worktree while another process uses its mount: the unmount fails, or detaches and leaves that process in a dead mount.

1. List the processes that use the mount: `lsof -n -w "$WT"`. Ignore the `artifact-fs daemon` of this worktree. Stop if any other process remains, including a shell or agent session whose working directory is inside `$WT`. Run the removal from a directory outside `$WT`.
2. Refuse when the worktree holds uncommitted work: `git -C "$WT" status --porcelain` prints something. Commit or discard that work first.
3. Stop the daemon and wait until it exits. A clean shutdown unmounts the repo.

```sh
kill "$(cat "$META/daemon.pid")"
while kill -0 "$(cat "$META/daemon.pid")" 2>/dev/null; do sleep 1; done
```

4. Confirm the mount is gone: `mount | grep -F " on $WT "` prints nothing. If it remains, unmount it: `fusermount3 -u "$WT"` on Linux, `diskutil unmount "$WT"` on macOS. Never run `rm -rf` on a path that is still a mount.
5. Restore the gitfile, unlock and remove the worktree, then delete its state:

```sh
mv "$META/gitfile" "$WT/.git"
git -C "$SRC" worktree unlock "$WT"
git -C "$SRC" worktree remove --force "$WT"
rm -rf "$META"
```

`git worktree remove` leaves the branch and its commits in `$SRC`. Delete the branch only after you merge it or save a ref for its commits.

After a daemon crash, the dead mount stays, and `$WT` fails with `Transport endpoint is not connected`. After a reboot, `$WT` is an empty directory. Either way, start the daemon again as in the create step, with the same `$STATE`. It unmounts a dead mount it finds there and mounts again.

## Common gotchas

- When `$SRC` is a blobless clone, a first read of a file fetches it from the promisor remote and needs network access.
- One daemon per worktree. A second daemon on one state root exits with an error.
- After a HEAD change on macOS FSKit, the mount can show the previous commit's names, sizes and content, with no known bound. A short read can return bytes that are not file data ([macfuse#1231](https://github.com/macfuse/macfuse/issues/1231)).
