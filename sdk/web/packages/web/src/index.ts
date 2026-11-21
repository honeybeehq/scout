import { createScout } from "./scout"
import type { GameConfig, QueuedGame, ScoutConfig, ScoutHandle } from "./types"

export { registerResolver } from "./resolvers"
export { isLibraryPath, parseFrame } from "./paths"
export { VERSION } from "./version"
export type * from "./types"

declare global {
  interface Window {
    __SCOUT__?: ScoutConfig
    __scoutGames?: QueuedGame[]
  }
}

const INSTANCE = Symbol.for("scout.web.instance")

type Host = Window & { [INSTANCE]?: ScoutHandle }

const idle: ScoutHandle = { connected: false, active: false, game: () => () => {}, stop() {} }

function parentRunsScout(): boolean {
  try {
    return window.top !== window && !!(window.top as Host | null)?.[INSTANCE]
  } catch {
    return false
  }
}

export function startScout(options: ScoutConfig = {}): ScoutHandle {
  if (typeof window === "undefined" || typeof WebSocket === "undefined") return idle
  const host = window as Host
  const existing = host[INSTANCE]
  if (existing) return existing
  if (parentRunsScout()) return idle
  const handle: ScoutHandle = createScout({ ...window.__SCOUT__, ...options }, () => {
    if (host[INSTANCE] === handle) delete host[INSTANCE]
    if (Array.isArray(window.__scoutGames)) window.__scoutGames.push = Array.prototype.push
  })
  host[INSTANCE] = handle
  const queue = window.__scoutGames ??= []
  const register = (entry: unknown) => {
    try {
      if (!entry || typeof entry !== "object") return
      const game = entry as QueuedGame
      if (game.v !== 1 || !(game.canvas instanceof HTMLCanvasElement) || typeof game.name !== "string" || !game.name || typeof game.build !== "string" || typeof game.describe !== "function" || typeof game.snapshot !== "function" || (game.highlight !== undefined && typeof game.highlight !== "function")) return
      let unregister = () => {}
      game.unregister = () => unregister()
      unregister = handle.game(game)
    } catch {}
  }
  queue.forEach(register)
  queue.push = (...entries: QueuedGame[]) => {
    const length = Array.prototype.push.apply(queue, entries)
    entries.forEach(register)
    return length
  }
  return handle
}

if (typeof window !== "undefined" && window.__SCOUT__) startScout()

export const scout = {
  game(config: GameConfig): () => void {
    if (typeof window === "undefined") return () => {}
    const handle = (window as Host)[INSTANCE] ?? (window.__SCOUT__ ? startScout() : null)
    return handle?.game(config) ?? (() => {})
  },
}
