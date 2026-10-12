export type EpochMs = number

declare module 'claude-code' {
  interface PluginState {
    'last-message-time': { lastAt: EpochMs | null; now: EpochMs }
  }
}
