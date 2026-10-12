# last-message-time

A Claude Code mod that tells you when the last message in a session was sent.

Resume a session, or come back to a tab you left open, and a dim line above the prompt shows:

```
Last message: Fri 9 Oct, 14:32 · 3d ago
```

It shows once the last message is 15 minutes old and hides when you send a prompt.

## Install

At a Claude Code prompt:

```
/plugin install last-message-time --marketplace dsfaccini/claude-code-last-message-time
```

Answer `y` to add the marketplace, then pick a scope.

## How it works

- On `--resume` or a fork, Claude Code's `SessionStart` event carries `seconds_since_last_response`; the mod turns that into a timestamp.
- Each prompt and each finished turn resets it.
- A one-minute tick keeps the age current while the session sits idle.

Message rows in the transcript carry no timestamp a mod can read, so per-message times aren't possible this way.

## Develop

```
claude plugin validate .
claude plugin test .
claude --plugin-dir .
```
