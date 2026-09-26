import { deepElementAt, frameOffset, promote, sameOriginFrames } from "./hit"
import type { Viewport } from "./types"

interface Sample {
  at: number
  element: Element | null
}

export interface PointerTracker {
  readonly current: Element | null
  readonly changedAt: number
  readonly inside: boolean
  readonly viewport: Viewport | null
  elementAt(at: number): Element | null
  stop(): void
}

const MAX_SAMPLES = 32
const SAMPLE_SLACK_MS = 30
const ZOOM_LEVELS = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]
const LISTEN = { capture: true, passive: true } as const

function snapZoom(estimate: number): number | null {
  const level = ZOOM_LEVELS.reduce((best, zoom) => (Math.abs(zoom - estimate) < Math.abs(best - estimate) ? zoom : best))
  return Math.abs(level - estimate) / level < 0.03 ? level : null
}

export function trackPointer(onChange: (element: Element | null) => void): PointerTracker {
  const samples: Sample[] = []
  const views = new Set<Window>()
  let x = 0
  let y = 0
  let inside = false
  let eventAt = 0
  let frame = 0
  let current: Element | null = null
  let changedAt = 0
  let viewport: Viewport | null = null
  let anchor: { screen: number; client: number } | null = null
  let positioned = false

  const hoveredLeaf = () => Array.from(document.querySelectorAll(":hover")).pop() ?? null

  const update = () => {
    frame = 0
    const leaf = !inside ? null : positioned ? deepElementAt(x, y) : hoveredLeaf()
    const element = leaf ? promote(leaf) : null
    if (element === current) return
    current = element
    changedAt = eventAt || Date.now()
    samples.push({ at: changedAt, element })
    if (samples.length > MAX_SAMPLES) samples.shift()
    onChange(element)
  }

  const schedule = () => {
    if (!frame) frame = requestAnimationFrame(update)
  }

  const measureViewport = (event: PointerEvent) => {
    let scale = viewport?.scale ?? 1
    if (anchor && Math.abs(x - anchor.client) >= 64) {
      scale = snapZoom((event.screenX - anchor.screen) / (x - anchor.client)) ?? scale
      anchor = { screen: event.screenX, client: x }
    } else if (!anchor) {
      anchor = { screen: event.screenX, client: x }
    }
    viewport = {
      x: Math.round(event.screenX - x * scale),
      y: Math.round(event.screenY - y * scale),
      scale,
    }
  }

  const onMove = (event: PointerEvent) => {
    const view = (event.view as Window | null) ?? window
    const offset = view === window ? { x: 0, y: 0 } : frameOffset(view)
    x = event.clientX + offset.x
    y = event.clientY + offset.y
    inside = true
    positioned = true
    eventAt = Math.round(view.performance.timeOrigin + event.timeStamp)
    measureViewport(event)
    schedule()
  }

  const onOut = (event: PointerEvent) => {
    const next = event.relatedTarget as Element | null
    if (next && !/^i?frame$/.test(next.localName)) return
    sameOriginFrames().forEach(listen)
    if (next) return
    inside = false
    eventAt = Date.now()
    schedule()
  }

  const onScroll = () => {
    eventAt = Date.now()
    schedule()
  }

  function listen(view: Window) {
    if (views.has(view)) return
    views.add(view)
    view.addEventListener("pointermove", onMove, LISTEN)
    view.addEventListener("pointerover", onMove, LISTEN)
    view.document.addEventListener("pointerout", onOut, LISTEN)
    view.addEventListener("scroll", onScroll, LISTEN)
  }

  listen(window)
  sameOriginFrames().forEach(listen)
  if (hoveredLeaf()) {
    inside = true
    schedule()
  }

  return {
    get current() {
      return current
    },
    get changedAt() {
      return changedAt
    },
    get inside() {
      return inside
    },
    get viewport() {
      return viewport
    },
    elementAt(at: number) {
      for (let index = samples.length - 1; index >= 0; index -= 1) {
        const sample = samples[index]!
        if (sample.at <= at + SAMPLE_SLACK_MS) return sample.element?.isConnected ? sample.element : null
      }
      return null
    },
    stop() {
      if (frame) cancelAnimationFrame(frame)
      views.forEach((view) => {
        try {
          view.removeEventListener("pointermove", onMove, LISTEN)
          view.removeEventListener("pointerover", onMove, LISTEN)
          view.document.removeEventListener("pointerout", onOut, LISTEN)
          view.removeEventListener("scroll", onScroll, LISTEN)
        } catch {
          return
        }
      })
      views.clear()
    },
  }
}
