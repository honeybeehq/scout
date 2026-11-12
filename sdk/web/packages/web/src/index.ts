import { createScout } from "./scout"
import type { ScoutConfig, ScoutHandle } from "./types"

export { registerResolver } from "./resolvers"
export { isLibraryPath, parseFrame } from "./paths"
export { VERSION } from "./version"
export type * from "./types"

declare global {
  interface Window {
    __SCOUT__?: ScoutConfig
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
  })
  host[INSTANCE] = handle
  return handle
}

if (typeof window !== "undefined" && window.__SCOUT__) startScout()

export const scout = {
  game(config: import("./types").GameConfig): () => void {
    if (typeof window === "undefined") return () => {}
    const handle = (window as Host)[INSTANCE] ?? (window.__SCOUT__ ? startScout() : null)
    return handle?.game(config) ?? (() => {})
  },
}
