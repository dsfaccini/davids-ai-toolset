// Runs the shell guards before every pi bash call. The guards live in the Claude Code plugin,
// ../../claude-code/plugins/shell-guards/hooks/; this file hands them the command and turns
// their verdict into pi's block result, so every harness runs the same guard code.
//
// The guards answer git and path questions from the directory the command runs in, which pi
// passes as ctx.cwd. It is not process.cwd(): `pi --session <id>` restores the session's
// recorded worktree while the process stays in the launch directory.

import { spawn } from 'node:child_process'
import { realpathSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// realpath, so a symlinked copy of this file still finds the repo it came from.
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
    cwd: string,
    guards: readonly string[] = [],
): Promise<string | undefined> {
    return new Promise((resolve) => {
        const child = spawn('bash', [RUN_GUARDS, ...guards], { cwd, stdio: ['pipe', 'ignore', 'pipe'] })
        let stderr = ''
        child.stderr.setEncoding('utf8')
        child.stderr.on('data', (chunk: string) => {
            stderr += chunk
        })
        child.on('error', () => resolve(undefined))
        child.on('close', (code) => resolve(code === 2 ? stderr.trim() || 'Blocked by shell-guards.' : undefined))
        child.stdin.on('error', () => {})
        child.stdin.end(JSON.stringify({ tool_name: 'Bash', tool_input: { command }, cwd }))
    })
}

// The slice of pi's extension API this file uses, declared structurally so the extension needs
// no dependency on pi's package.
interface ToolCallEvent {
    readonly toolName: string
    readonly input: unknown
}

interface ToolCallContext {
    readonly cwd: string
}

interface ToolCallBlock {
    readonly block: boolean
    readonly reason: string
}

interface ExtensionApi {
    on(
        event: 'tool_call',
        handler: (event: ToolCallEvent, ctx: ToolCallContext) => Promise<ToolCallBlock | undefined>,
    ): void
}

export async function checkToolCall(event: ToolCallEvent, ctx: ToolCallContext): Promise<ToolCallBlock | undefined> {
    if (event.toolName !== 'bash') return undefined
    const input = event.input
    if (typeof input !== 'object' || input === null || !('command' in input)) return undefined
    if (typeof input.command !== 'string' || !input.command) return undefined
    const reason = await guardReason(input.command, ctx.cwd)
    return reason === undefined ? undefined : { block: true, reason }
}

export default function shellGuards(pi: ExtensionApi): void {
    pi.on('tool_call', checkToolCall)
}
