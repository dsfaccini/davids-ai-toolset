// Checks the opencode2 adapter end to end: each guard's verdict reaches opencode2 as a thrown
// deny, the directory a command runs in decides the repo-dependent guards, and non-shell tools
// pass. Each guard's full case matrix runs in its own test under
// claude-code/plugins/shell-guards/hooks/.
//
// Run: bun test opencode/shell-guards
import { afterAll, expect, test } from 'bun:test'
import { execFileSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, relative } from 'node:path'

import plugin, { commandDirectory, guardReason } from './shell-guards.ts'

process.env.RECURSIVE_DELETE_ROOTS = ''

const fixtures = mkdtempSync(join(tmpdir(), 'opencode-shell-guards-'))
afterAll(() => rmSync(fixtures, { recursive: true, force: true }))

function fixtureRepo(name: string, remote?: string): string {
    const directory = join(fixtures, name)
    mkdirSync(directory)
    execFileSync('git', ['-C', directory, 'init', '-q'])
    if (remote) execFileSync('git', ['-C', directory, 'remote', 'add', 'origin', remote])
    return directory
}

// Scope is repo identity, so the in/out pair differs only in the remote name.
const PLAIN = fixtureRepo('plain')
const PYAI = fixtureRepo('pydantic-ai', 'https://github.com/pydantic/pydantic-ai.git')
const NOT_PYAI = fixtureRepo('pydantic-ai-tooling', 'https://github.com/pydantic/pydantic-ai-tooling.git')

const cases: ReadonlyArray<readonly [string, string, string, boolean]> = [
    ['block-force-push.sh', PLAIN, 'git push --force', true],
    ['block-force-push.sh', PLAIN, 'git push origin main', false],
    ['block-busy-loop.sh', PLAIN, 'until [ -f /tmp/done ]; do :; done', true],
    ['block-busy-loop.sh', PLAIN, 'until [ -f /tmp/done ]; do sleep 2; done', false],
    ['block-broad-pkill.sh', PLAIN, 'kill $(pgrep -f cat)', true],
    ['block-broad-pkill.sh', PLAIN, 'pkill -P $$ -x cat', false],
    ['block-heavy-tests.sh', PYAI, 'tox', true],
    ['block-heavy-tests.sh', NOT_PYAI, 'tox', false],
    ['block-broad-typecheck.sh', PYAI, 'make typecheck', true],
    ['block-broad-typecheck.sh', NOT_PYAI, 'make typecheck', false],
    ['disallow-recursive-delete.py', PLAIN, 'rm -rf /fixture-home/notes', true],
    ['disallow-recursive-delete.py', PLAIN, 'rm -rf /tmp/opencode-shell-guards-scratch', false],
]

for (const [guard, cwd, command, blocked] of cases) {
    test(`${guard} ${blocked ? 'blocks' : 'allows'}: ${command}`, async () => {
        expect((await guardReason(command, cwd, [guard])) !== undefined).toBe(blocked)
    })
}

// The deny path itself: opencode2 aborts a tool call when the hook throws, so the plugin has to
// register on tool/execute.before and throw the reason rather than return it.
let registered: ((call: unknown) => Promise<void>) | undefined
plugin.setup({
    tool: {
        hook: (name: string, callback: (call: unknown) => Promise<void>) => {
            if (name === 'execute.before') registered = callback
        },
    },
    session: { get: async (_args: { sessionID: string }) => ({ location: { directory: PLAIN } }) },
})

async function callTool(tool: string, command: string, workdir?: string): Promise<string | undefined> {
    if (!registered) throw new Error('plugin registered no execute.before hook')
    try {
        await registered({ tool, sessionID: 'ses_test', input: workdir === undefined ? { command } : { command, workdir } })
        return undefined
    } catch (error) {
        return error instanceof Error ? error.message : String(error)
    }
}

test('throws on a blocked shell command', async () => {
    expect(await callTool('shell', 'git push --force')).toStartWith('Force push blocked')
})

test('allows an ordinary shell command', async () => {
    expect(await callTool('shell', 'git push origin main')).toBeUndefined()
})

test('ignores non-shell tools', async () => {
    expect(await callTool('edit', 'git push --force')).toBeUndefined()
})

// The session directory above is PLAIN (out of scope), so only workdir can bring a
// pydantic-ai guard into play.
test('workdir into a pydantic-ai repo brings a scoped guard into play', async () => {
    expect(await callTool('shell', 'tox --version', PYAI)).toStartWith('Blocked:')
})

test('a workdir relative to the session directory resolves the same way', async () => {
    expect(await callTool('shell', 'tox --version', relative(PLAIN, PYAI))).toStartWith('Blocked:')
})

test('a workdir outside a pydantic-ai repo stays out of scope', async () => {
    expect(await callTool('shell', 'tox --version', NOT_PYAI)).toBeUndefined()
})

const directoryCases: ReadonlyArray<readonly [string | undefined, string | undefined, string | undefined]> = [
    [PLAIN, undefined, PLAIN],
    [PLAIN, PYAI, PYAI],
    [PLAIN, relative(PLAIN, PYAI), PYAI],
    // opencode2 spawns with `cwd: workdir ?? location.directory`, and an empty string is not
    // nullish: it resolves back to the session directory rather than defaulting to it.
    [PLAIN, '', PLAIN],
    // No session directory: an absolute workdir still locates the command, a relative one cannot.
    [undefined, PYAI, PYAI],
    [undefined, 'sub', undefined],
    [undefined, undefined, undefined],
]

for (const [session, workdir, want] of directoryCases) {
    test(`commandDirectory(${session}, ${workdir}) === ${want}`, () => {
        expect(commandDirectory(session, workdir)).toBe(want)
    })
}
