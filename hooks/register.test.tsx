import type { RenderSurface } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

const MINUTE_MS = 60_000
const DAY_MS = 24 * 60 * MINUTE_MS
const SURFACES: RenderSurface[] = ['terminal', 'desktop']
const BAND_PROPS = { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 100, scroll: { offset: 0, bodyRows: 10 }, view: {} }

test('a resumed session shows when its last message was sent', async ($, on) => {
  mock.clock(on, { now: 10 * DAY_MS })
  on('classic.SessionStart', () => ({}))
  await $.classic.SessionStart({ source: 'resume', seconds_since_last_response: 3 * DAY_MS / 1000 })

  for (const surface of SURFACES) {
    const ui = await $.ui.mount({ plugin: 'last-message-time', component: 'AbovePrompt', props: BAND_PROPS, surface })
    expect(await ui.find({ type: 'Text', text: /Last message: .* · 3d ago/ })).toBeDefined()
    await ui.unmount()
  }
})

test('a recent message shows nothing until it goes stale', async ($, on) => {
  const clock = mock.clock(on, { now: 10 * DAY_MS })
  on('classic.SessionStart', () => ({}))
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('ui.render', () => ({ type: 'Box' }))
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.classic.SessionStart({ source: 'resume', seconds_since_last_response: 5 * 60 })

  const ui = await $.ui.mount({ plugin: 'last-message-time', component: 'AbovePrompt', props: BAND_PROPS, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /Last message/ })).toBeUndefined()

  await clock.advance(20 * MINUTE_MS)
  expect(await ui.find({ type: 'Text', text: /Last message: .* · 25m ago/ })).toBeDefined()
  await ui.unmount()
})

test('a session.start after the resume keeps the band', async ($, on) => {
  mock.clock(on, { now: 10 * DAY_MS })
  on('classic.SessionStart', () => ({}))
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  await $.classic.SessionStart({ source: 'resume', seconds_since_last_response: 2 * 60 * 60 })
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  const ui = await $.ui.mount({ plugin: 'last-message-time', component: 'AbovePrompt', props: BAND_PROPS, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /Last message: .* · 2h ago/ })).toBeDefined()
  await ui.unmount()
})

test('/clear forgets the last message', async ($, on) => {
  mock.clock(on, { now: 10 * DAY_MS })
  on('classic.SessionStart', () => ({}))
  on('ui.render', () => ({ type: 'Box' }))
  await $.classic.SessionStart({ source: 'resume', seconds_since_last_response: 2 * 60 * 60 })
  await $.classic.SessionStart({ source: 'clear' })

  const ui = await $.ui.mount({ plugin: 'last-message-time', component: 'AbovePrompt', props: BAND_PROPS, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /Last message/ })).toBeUndefined()
  await ui.unmount()
})
