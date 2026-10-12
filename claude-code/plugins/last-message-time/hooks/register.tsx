import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

const STALE_MS = 15 * 60_000
const MINUTE_MS = 60_000

const lastAt = atom({ plugin: 'last-message-time', key: 'lastAt' }, null)
const now = atom({ plugin: 'last-message-time', key: 'now' }, 0)

const pad = (n: number) => String(n).padStart(2, '0')

function formatAge(ms: number): string {
  const minutes = Math.floor(ms / MINUTE_MS)
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 48) return `${hours}h ago`
  return `${Math.floor(hours / 24)}d ago`
}

function formatTime(ms: number): string {
  const d = new Date(ms)
  const day = d.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' })
  return `${day}, ${pad(d.getHours())}:${pad(d.getMinutes())}`
}

async function tick($: EngineInterface): Promise<number> {
  const t = await $.clock.now()
  await update($, now, () => t)
  return t
}

async function markNow($: EngineInterface) {
  const t = await tick($)
  await update($, lastAt, () => t)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await tick($)
    $.clock.every(MINUTE_MS, () => tick($))
    return next(e)
  })

  on('classic.SessionStart', async ($, e, next) => {
    const awaySeconds = e.seconds_since_last_response
    if ((e.source === 'resume' || e.source === 'fork') && awaySeconds !== undefined) {
      const t = await tick($)
      await update($, lastAt, () => t - awaySeconds * 1000)
    } else if (e.source === 'clear') {
      await update($, lastAt, () => null)
    }
    return next(e)
  })

  on('prompt.submit', async ($, e, next) => {
    await markNow($)
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    await markNow($)
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const at = await read($, lastAt)
    const t = await read($, now)
    if (e.props.hasSurvey || at === null || t - at < STALE_MS) {
      return next(e)
    }

    const { Text } = $.ui.resolve(e)
    return <Text dimColor>Last message: {formatTime(at)} · {formatAge(t - at)}</Text>
  })
}
