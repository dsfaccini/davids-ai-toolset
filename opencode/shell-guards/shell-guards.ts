// Runs the shell guards before every opencode2 shell call. The guards live in the Claude Code
// plugin, ../../claude-code/plugins/shell-guards/hooks/; this file hands them the command and
// turns their verdict into opencode2's deny, so every harness runs the same guard code.
//
// Three things about opencode2's plugin API shape this file, all different from opencode v1:
//
//   1. The shell tool is `shell`, not `bash`, and its argument arrives at input.command (there is
//      no `args` object). It also takes an optional input.workdir, so the directory a command runs
//      in is not always the session's. See commandDirectory.
//   2. A plugin denies a tool call by throwing; the thrown message is what the model reads.
//      Returning undefined allows the call.
//   3. process.cwd() is the background service's cwd, never the project, so the directory a
//      command will run in is derived per call and the guards run there.

import { spawn } from 'node:child_process'
import { realpathSync } from 'node:fs'
import { dirname, isAbsolute, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// realpath, so the symlink in opencode's plugin folder still finds the repo it points into.
const RUN_GUARDS = join(
    dirname(realpathSync(fileURLToPath(import.meta.url))),
    '..', '..', 'claude-code', 'plugins', 'shell-guards', 'hooks', 'run-guards.sh',
)

/**
 * The deny reason for a shell command, or undefined to allow it. `guards` names guard files to
 * run instead of all of them. A guard that cannot run allows the command.
 */
export function guardReason(
    command: string,
    cwd: string | undefined,
    guards: readonly string[] = [],
): Promise<string | undefined> {
    return new Promise((done) => {
        const child = spawn('bash', [RUN_GUARDS, ...guards], { cwd, stdio: ['pipe', 'ignore', 'pipe'] })
        let stderr = ''
        child.stderr.setEncoding('utf8')
        child.stderr.on('data', (chunk: string) => {
            stderr += chunk
        })
        child.on('error', () => done(undefined))
        child.on('close', (code) => done(code === 2 ? stderr.trim() || 'Blocked by shell-guards.' : undefined))
        child.stdin.on('error', () => {})
        child.stdin.end(JSON.stringify({ tool_name: 'Bash', tool_input: { command }, cwd }))
    })
}

// ---------------------------------------------------------------------------
// opencode2 plugin surface
//
// The published @opencode-ai/plugin types do not cover the two domains this plugin touches, so
// they are declared here structurally and validated at runtime before use.
// ---------------------------------------------------------------------------

interface PluginContext {
    readonly tool: { hook(name: string, callback: (call: unknown) => Promise<void>): unknown }
    readonly session: { get(args: { sessionID: string }): Promise<unknown> }
}

interface ShellCall {
    readonly sessionID: string
    readonly command: string
    readonly workdir: string | undefined
}

function hasKey<K extends string>(value: unknown, key: K): value is Record<K, unknown> {
    return typeof value === 'object' && value !== null && key in value
}

function isPluginContext(value: unknown): value is PluginContext {
    if (!hasKey(value, 'tool') || !hasKey(value.tool, 'hook') || typeof value.tool.hook !== 'function') return false
    return hasKey(value, 'session') && hasKey(value.session, 'get') && typeof value.session.get === 'function'
}

// The hook fires for every tool; only shell calls carry a command to inspect.
function toShellCall(call: unknown): ShellCall | undefined {
    if (!hasKey(call, 'tool') || call.tool !== 'shell') return undefined
    if (!hasKey(call, 'sessionID') || typeof call.sessionID !== 'string') return undefined
    if (!hasKey(call, 'input')) return undefined
    const input = call.input
    if (!hasKey(input, 'command') || typeof input.command !== 'string') return undefined
    if (!input.command) return undefined
    const workdir = hasKey(input, 'workdir') && typeof input.workdir === 'string' ? input.workdir : undefined
    return { sessionID: call.sessionID, command: input.command, workdir }
}

// The directory the command will actually run in: opencode2's shell tool spawns with
// `cwd: workdir ?? location.directory` and resolves that against the session's directory, so a
// workdir naming another repo moves the command out of the session's scope entirely.
export function commandDirectory(
    session: string | undefined,
    workdir: string | undefined,
): string | undefined {
    if (workdir === undefined) return session
    if (isAbsolute(workdir)) return workdir
    // Without the session directory there is nothing to resolve a relative workdir against, and
    // process.cwd() is the background service's home rather than any project.
    return session === undefined ? undefined : resolve(session, workdir)
}

function sessionDirectory(session: unknown): string | undefined {
    if (!hasKey(session, 'location')) return undefined
    const location = session.location
    if (!hasKey(location, 'directory') || typeof location.directory !== 'string') return undefined
    return location.directory
}

export default {
    id: 'shell-guards',
    setup: (context: unknown) => {
        if (!isPluginContext(context)) return

        // session.get is a round trip on every tool call, and a session's directory never
        // changes, so each session is looked up once.
        const directories = new Map<string, string | undefined>()
        const directoryOf = async (sessionID: string): Promise<string | undefined> => {
            if (directories.has(sessionID)) return directories.get(sessionID)
            const directory = sessionDirectory(await context.session.get({ sessionID }))
            directories.set(sessionID, directory)
            return directory
        }

        context.tool.hook('execute.before', async (call: unknown) => {
            const shell = toShellCall(call)
            if (!shell) return

            let reason: string | undefined
            try {
                reason = await guardReason(shell.command, commandDirectory(await directoryOf(shell.sessionID), shell.workdir))
            } catch {
                // Fail open: a broken session lookup must not block real work.
                return
            }
            // Throwing aborts the tool call; the message is what the model reads.
            if (reason) throw new Error(reason)
        })
    },
}
