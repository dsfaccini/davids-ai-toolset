// Checks the pi adapter end to end: each guard's verdict reaches pi as a block, ctx.cwd decides
// the repo-dependent guards, and non-bash tools pass. Each guard's full case matrix runs in its
// own test under claude-code/plugins/shell-guards/hooks/.
//
// Run: bun test pi/shell-guards
import { afterAll, expect, test } from 'bun:test'
import { execFileSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, rmSync, symlinkSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import shellGuards, { checkToolCall, guardReason } from './shell-guards.ts'

process.env.RECURSIVE_DELETE_ROOTS = ''

const fixtures = mkdtempSync(join(tmpdir(), 'pi-shell-guards-'))
afterAll(() => rmSync(fixtures, { recursive: true, force: true }))

function fixtureRepo(name: string, remote?: string): string {
    const directory = join(fixtures, name)
    mkdirSync(directory)
    execFileSync('git', ['-C', directory, 'init', '-q'])
    if (remote) execFileSync('git', ['-C', directory, 'remote', 'add', 'origin', remote])
    return directory
}

const PLAIN = fixtureRepo('plain')
const PYAI = fixtureRepo('pydantic-ai', 'https://github.com/pydantic/pydantic-ai.git')
const ALIASES = fixtureRepo('aliases')
execFileSync('git', ['-C', ALIASES, 'config', 'alias.fp', 'push --force'])

const cases: ReadonlyArray<readonly [string, string, string, boolean]> = [
    ['block-force-push.sh', PLAIN, 'git push --force', true],
    ['block-force-push.sh', PLAIN, 'git push origin main', false],
    ['block-force-push.sh', ALIASES, 'git fp', true],
    ['block-busy-loop.sh', PLAIN, 'while kill -0 $pid; do :; done', true],
    ['block-busy-loop.sh', PLAIN, 'while kill -0 $pid; do sleep 1; done', false],
    ['block-broad-pkill.sh', PLAIN, 'pkill -f worker', true],
    ['block-broad-pkill.sh', PLAIN, 'pkill -x worker', false],
    ['block-heavy-tests.sh', PYAI, 'uv run pytest -n auto', true],
    ['block-heavy-tests.sh', PLAIN, 'uv run pytest -n auto', false],
    ['block-broad-typecheck.sh', PYAI, 'uv run pyright', true],
    ['block-broad-typecheck.sh', PYAI, 'uv run pyright tests/test_x.py', false],
    ['disallow-recursive-delete.py', PLAIN, 'rm -rf /fixture-home/notes', true],
    ['disallow-recursive-delete.py', PLAIN, 'rm -rf /tmp/pi-shell-guards-scratch', false],
    // A heredoc body is data: the guard must receive the command intact, newlines included.
    ['block-broad-pkill.sh', PLAIN, "cat > stop.sh <<'EOF'\npkill -f worker\nEOF", false],
]

for (const [guard, cwd, command, blocked] of cases) {
    test(`${guard} ${blocked ? 'blocks' : 'allows'}: ${command}`, async () => {
        expect((await guardReason(command, cwd, [guard])) !== undefined).toBe(blocked)
    })
}

test('blocks a bash call with the guard reason', async () => {
    const result = await checkToolCall({ toolName: 'bash', input: { command: 'git push --force' } }, { cwd: PLAIN })
    expect(result?.block).toBe(true)
    expect(result?.reason).toStartWith('Force push blocked')
})

test('ctx.cwd decides the pydantic-ai scope', async () => {
    const command = { toolName: 'bash', input: { command: 'uv run pyright' } }
    expect((await checkToolCall(command, { cwd: PYAI }))?.block).toBe(true)
    expect(await checkToolCall(command, { cwd: PLAIN })).toBeUndefined()
})

test('allows an ordinary bash call', async () => {
    expect(await checkToolCall({ toolName: 'bash', input: { command: 'git status' } }, { cwd: PLAIN })).toBeUndefined()
})

test('ignores other tools', async () => {
    expect(await checkToolCall({ toolName: 'write', input: { command: 'git push --force' } }, { cwd: PLAIN })).toBeUndefined()
})

test('registers a tool_call handler', () => {
    const events: string[] = []
    shellGuards({ on: (event) => { events.push(event) } })
    expect(events).toEqual(['tool_call'])
})

function hasGuardReason(module: unknown): module is { readonly guardReason: typeof guardReason } {
    return typeof module === 'object' && module !== null && 'guardReason' in module
        && typeof module.guardReason === 'function'
}

test('a symlinked copy still finds the guards', async () => {
    const link = join(fixtures, 'linked-shell-guards.ts')
    symlinkSync(join(import.meta.dir, 'shell-guards.ts'), link)
    const linked: unknown = await import(link)
    if (!hasGuardReason(linked)) throw new Error('the symlinked module exports no guardReason')
    expect(await linked.guardReason('git push --force', PLAIN)).toStartWith('Force push blocked')
})
