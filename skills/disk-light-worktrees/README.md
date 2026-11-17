# disk-light-worktrees

An Agent Skill that teaches an agent to create git worktrees that take a fraction of a normal checkout's disk. It uses [artifact-fs](https://github.com/dsfaccini/artifact-fs), a FUSE filesystem that serves a worktree lazily from a blobless clone, with one blob cache shared by every worktree.

The skill covers installing artifact-fs from source, creating, checking and removing a worktree, which files to symlink and which to copy into a new worktree, and when to skip artifact-fs.

Measured on a 16-core Linux box with ext4: a fresh pydantic-ai worktree took about 43 MiB, against about 371 MiB for `git worktree add`, about 88% less. That counts the checkout, its git dir and its virtualenv's private bytes, median of three runs, and leaves out the shared blob cache. The cost is latency on commands that walk the tree: `rg` took 0.59 s against 0.03 s, cold.

## Requirements

- Linux with `fuse3` and a readable and writable `/dev/fuse`, or macOS 26 or newer with macFUSE 5.5 and its FSKit backend.
- `git`, and Go to build artifact-fs. The skill's install section has the steps.

## Install

```sh
npx skills add dsfaccini/davids-ai-toolset --skill disk-light-worktrees
```

Or copy the `skills/disk-light-worktrees` folder into the harness's skills directory:

| Harness | Skills directory |
| --- | --- |
| Claude Code | `~/.claude/skills/` |
| Codex | `~/.agents/skills/` |
| pi | `~/.agents/skills/` |
| opencode | `~/.agents/skills/` |

## Develop

```sh
bash skills/disk-light-worktrees/SKILL.test.sh
```

The test checks the skill's frontmatter, that its description names when to load and skip it, that its shell blocks parse, run the commands the skill relies on and pass only flags the artifact-fs CLI defines, and that it holds no home paths, secrets or security material. CI runs every `*.test.sh` in the repo.
