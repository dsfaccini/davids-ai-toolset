#!/usr/bin/env python3
"""Deny recursive deletion unless every target resolves inside an approved root.

Approved roots are the system temporary directories plus every directory listed in
RECURSIVE_DELETE_ROOTS (separated like PATH, `~` expanded). Set it in the environment
that launches the harness.

Harnesses disagree on how a PreToolUse hook says "no":
  Claude Code / Grok Build / mastracode -- message on stderr, exit 2
  Codex                                 -- hookSpecificOutput JSON on stdout, exit 0
`--protocol codex` selects the latter.
"""

from __future__ import annotations

import json
import os
import shlex
import sys
from pathlib import Path


SHELL_OPERATORS = {";", "&&", "||", "|", "&", "(", ")"}
ROOTS_VARIABLE = "RECURSIVE_DELETE_ROOTS"


def _deny(reason: str) -> int:
    if sys.argv[1:3] == ["--protocol", "codex"]:
        print(
            json.dumps(
                {
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "deny",
                        "permissionDecisionReason": reason,
                    }
                }
            )
        )
        return 0
    print(reason, file=sys.stderr)
    print(json.dumps({"decision": "deny", "reason": reason}))
    return 2


def _tokens(command: str) -> list[str] | None:
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()")
        lexer.whitespace_split = True
        lexer.commenters = ""
        return list(lexer)
    except ValueError:
        return None


def _is_recursive(options: list[str]) -> bool:
    return any(
        option == "--recursive"
        or (option.startswith("-") and not option.startswith("--") and any(flag in option[1:] for flag in "rR"))
        for option in options
    )


def _expand_target(target: str, home: Path, tmpdir: Path, cwd: Path) -> str | None:
    replacements = {
        "$HOME": str(home),
        "${HOME}": str(home),
        "$TMPDIR": str(tmpdir),
        "${TMPDIR}": str(tmpdir),
        "$PWD": str(cwd),
        "${PWD}": str(cwd),
    }
    expanded = target
    for variable, value in replacements.items():
        expanded = expanded.replace(variable, value)
    if expanded.startswith("~"):
        expanded = str(home) + expanded[1:]
    if any(marker in expanded for marker in ("$", "`", "$(", "*", "?", "[", "]", "{", "}")):
        return None
    return expanded


def _approved_roots(tmpdir: Path) -> tuple[Path, ...]:
    configured = (
        Path(entry).expanduser() for entry in os.environ.get(ROOTS_VARIABLE, "").split(os.pathsep) if entry
    )
    return tuple(
        root.resolve(strict=False) for root in (tmpdir, Path("/tmp"), Path("/private/tmp"), *configured)
    )


def _is_strictly_below(target: Path, root: Path) -> bool:
    return target != root and root in target.parents


def _target_is_safe(raw_target: str, cwd: Path, home: Path, tmpdir: Path) -> bool:
    expanded = _expand_target(raw_target, home, tmpdir, cwd)
    if expanded is None:
        return False
    candidate = Path(expanded)
    if not candidate.is_absolute():
        candidate = cwd / candidate
    resolved = candidate.resolve(strict=False)
    if resolved == Path("/") or resolved == home or resolved in home.parents:
        return False
    return any(_is_strictly_below(resolved, root) for root in _approved_roots(tmpdir))


def _recursive_rm_targets(tokens: list[str]) -> list[list[str]] | None:
    commands: list[list[str]] = []
    segment: list[str] = []
    for token in tokens + [";"]:
        if token in SHELL_OPERATORS:
            if segment:
                commands.append(segment)
                segment = []
        else:
            segment.append(token)

    recursive_targets: list[list[str]] = []
    for command in commands:
        rm_index = next((index for index, word in enumerate(command) if Path(word).name == "rm"), None)
        if rm_index is None:
            continue
        options: list[str] = []
        targets: list[str] = []
        options_done = False
        for word in command[rm_index + 1 :]:
            if not options_done and word == "--":
                options_done = True
            elif not options_done and word.startswith("-"):
                options.append(word)
            else:
                options_done = True
                targets.append(word)
        if _is_recursive(options):
            if not targets:
                return None
            recursive_targets.append(targets)
    return recursive_targets


def main() -> int:
    payload = json.load(sys.stdin)
    tool_name = payload.get('tool_name') or payload.get('toolName')
    if tool_name in {'apply_patch', 'ApplyPatch', 'Edit', 'Write'}:
        return 0
    tool_input = payload.get("tool_input") or payload.get("toolInput") or {}
    command = tool_input.get("command") or tool_input.get("cmd") or ""
    if not isinstance(command, str):
        return 0

    tokens = _tokens(command)
    if tokens is None:
        return _deny("Recursive deletion command could not be parsed safely.")

    target_groups = _recursive_rm_targets(tokens)
    if target_groups is None:
        return _deny("Recursive deletion without an explicit target is blocked.")
    if not target_groups:
        return 0

    home = Path.home().resolve()
    tmpdir = Path(os.environ.get("TMPDIR", "/private/tmp")).resolve(strict=False)
    raw_cwd = tool_input.get("workdir") or tool_input.get("cwd") or payload.get("cwd") or os.getcwd()
    cwd = Path(raw_cwd).resolve(strict=False)
    for targets in target_groups:
        for target in targets:
            if not _target_is_safe(target, cwd, home, tmpdir):
                roots = ", ".join(str(root) for root in dict.fromkeys(_approved_roots(tmpdir)))
                return _deny(
                    f"Recursive deletion is allowed only for resolved targets strictly inside an approved root: {roots}. "
                    f"The user can approve more roots with {ROOTS_VARIABLE}."
                )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
