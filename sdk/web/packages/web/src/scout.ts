import { clip, labelOf, roleOf, textOf } from "./aria"
import { connectBridge, type Incoming } from "./bridge"
import { createDescriber, elementById } from "./describe"
import { createOverlay, type Overlay } from "./overlay"
import { trackPointer, type PointerTracker } from "./pointer"
import { registeredResolvers } from "./resolvers"
import { currentRoute, watchRoute } from "./route"
import { captureSignals, type SignalRecord } from "./signals"
import { cleanStack } from "./stack"
import type { ElementDescriptor, ScoutConfig, ScoutHandle, SourceLocation } from "./types"
import { VERSION } from "./version"

const DEFAULT_PORTS = [47811, 47812, 47813, 47814, 47815, 47816, 47817, 47818, 47819]
const HOVER_INTERVAL_MS = 250
const AIM_HOVER_INTERVAL_MS = 50
const AIM_REPEAT_MS = 1000
const PIN_SOURCE_BUDGET_MS = 120
const CONTEXT_DELAY_MS = 150
const SIGNAL_RING = 50
const SIGNAL_REPLAY_MS = 30_000
const SIGNAL_BURST = 20

function chipText(element: Element, source: SourceLocation | null): string {
  const role = roleOf(element)
  const kind = role ? role[0]!.toUpperCase() + role.slice(1) : element.localName
  const name = clip(labelOf(element, role) ?? textOf(element), 40)
  const where = source ? ` · ${source.file.split("/").pop()}${source.line ? `:${source.line}` : ""}` : ""
  return `${name ? `${kind} "${name}"` : kind}${where}`
}

function query(selector: string): Element | null {
  try {
    return document.querySelector(selector)
  } catch {
    return null
  }
}

export function createScout(config: ScoutConfig, onStop: () => void): ScoutHandle {
  const roots = { projectRoot: config.projectRoot, serverRoot: config.serverRoot }
  const describe = createDescriber(roots, config.props ?? "off")
  const signals: SignalRecord[] = []
  const recentSignalTimes: number[] = []
  let active = false
  let aiming = false
  let pointer: PointerTracker | null = null
  let overlay: Overlay | null = null
  let stopRoute: (() => void) | null = null
  let hoverTimer: ReturnType<typeof setTimeout> | undefined
  let repeatTimer: ReturnType<typeof setInterval> | undefined
  let contextTimer: ReturnType<typeof setTimeout> | undefined
  const chipSources = new WeakMap<Element, SourceLocation | null>()
  let lastHovered: Element | null = null
  let lastHoverAt = 0
  let hoverEpoch = 0
  let hoverInFlight = false
  let resendCurrent = false
  let lastContext = ""

  const aimAt = (element: Element | null) => {
    overlay?.aim(element, element ? chipText(element, chipSources.get(element) ?? null) : "")
  }

  const scheduleHover = () => {
    if (hoverTimer || hoverInFlight) return
    const interval = aiming ? AIM_HOVER_INTERVAL_MS : HOVER_INTERVAL_MS
    hoverTimer = setTimeout(sendHover, Math.max(0, lastHoverAt + interval - performance.now()))
  }

  function sendHover() {
    hoverTimer = undefined
    const element = pointer?.inside ? pointer.current : null
    if (!active || !element || hoverInFlight || (element === lastHovered && !resendCurrent)) return
    const at = element === lastHovered ? Date.now() : pointer!.changedAt
    const epoch = hoverEpoch
    resendCurrent = false
    hoverInFlight = true
    void describe(element)
      .catch(() => null)
      .then((descriptor) => {
        hoverInFlight = false
        if (!descriptor || epoch !== hoverEpoch || !active) return
        lastHovered = element
        lastHoverAt = performance.now()
        bridge.send({ type: "hover", at, element: descriptor, viewport: pointer?.viewport ?? null })
        chipSources.set(element, descriptor.source)
        if (aiming && pointer?.current === element) aimAt(element)
        if (pointer?.current !== element) scheduleHover()
      })
  }

  const resendHover = () => {
    resendCurrent = true
    scheduleHover()
  }

  const onPointerChange = (element: Element | null) => {
    if (aiming) aimAt(element)
    scheduleHover()
  }

  const sendContext = () => {
    contextTimer = undefined
    if (!active) return
    const context = {
      type: "context",
      route: currentRoute(config.route),
      url: `${location.origin}${location.pathname}`,
      title: document.title || null,
    }
    const key = JSON.stringify(context)
    if (key === lastContext) return
    if (bridge.send(context)) lastContext = key
  }

  const scheduleContext = () => {
    clearTimeout(contextTimer)
    contextTimer = setTimeout(sendContext, CONTEXT_DELAY_MS)
  }

  const sendSignal = async (signal: SignalRecord) => {
    signal.sent = true
    const { sent: _sent, ...fields } = signal
    const stack = await cleanStack(signal.stack, roots)
    if (!active || !bridge.send({ type: "signal", ...fields, stack })) signal.sent = false
  }

  const onSignal = (signal: SignalRecord) => {
    const now = Date.now()
    while (recentSignalTimes.length > 0 && recentSignalTimes[0]! < now - 1000) recentSignalTimes.shift()
    const previous = signals[signals.length - 1]
    if (recentSignalTimes.length >= SIGNAL_BURST) return
    if (previous && previous.message === signal.message && signal.at - previous.at < 1000) return
    recentSignalTimes.push(now)
    signals.push(signal)
    if (signals.length > SIGNAL_RING) signals.shift()
    if (active) void sendSignal(signal)
  }

  const setAim = (requested: boolean) => {
    const next = requested && active
    if (next === aiming) return
    aiming = next
    clearInterval(repeatTimer)
    clearTimeout(hoverTimer)
    hoverTimer = undefined
    if (aiming) {
      overlay ??= createOverlay()
      aimAt(pointer?.inside ? pointer.current : null)
      resendHover()
      repeatTimer = setInterval(() => {
        if (performance.now() - lastHoverAt >= AIM_REPEAT_MS / 2) resendHover()
      }, AIM_REPEAT_MS)
    } else {
      overlay?.aim(null)
    }
  }

  const setActive = (next: boolean) => {
    if (next === active) return
    active = next
    if (active) {
      pointer = trackPointer(onPointerChange)
      stopRoute = watchRoute(scheduleContext)
      lastContext = ""
      sendContext()
      const since = Date.now() - SIGNAL_REPLAY_MS
      signals.filter((signal) => !signal.sent && signal.at >= since).forEach((signal) => void sendSignal(signal))
    } else {
      setAim(false)
      pointer?.stop()
      pointer = null
      stopRoute?.()
      stopRoute = null
      clearTimeout(hoverTimer)
      clearTimeout(contextTimer)
      hoverTimer = undefined
      hoverInFlight = false
      resendCurrent = false
      lastHovered = null
      hoverEpoch += 1
    }
  }

  const pin = async (message: Incoming) => {
    const at = typeof message.at === "number" ? message.at : Date.now()
    const element = active && pointer ? pointer.elementAt(at) : null
    const descriptor: ElementDescriptor | null = element ? await describe(element, PIN_SOURCE_BUDGET_MS) : null
    bridge.send({ type: "pinned", id: message.id, element: descriptor, viewport: pointer?.viewport ?? null })
    if (element && descriptor) {
      overlay ??= createOverlay()
      overlay.flash(element, "flare", 600)
    }
  }

  const highlight = (message: Incoming) => {
    const element = typeof message.elementId === "string"
      ? elementById(message.elementId)
      : typeof message.selector === "string" ? query(message.selector) : null
    if (!element) return
    const duration = Math.min(Math.max(Number(message.durationMs) || 1500, 100), 10_000)
    overlay ??= createOverlay()
    overlay.flash(element, message.style === "flare" ? "flare" : "beam", duration, chipText(element, null))
  }

  const detectFramework = () => {
    for (const resolver of registeredResolvers()) {
      try {
        const found = resolver.detect()
        if (found) return { name: resolver.name, version: found.version }
      } catch {
        continue
      }
    }
    return null
  }

  const hello = () => {
    const detected = detectFramework()
    const hint = config.framework
    const name = detected?.name ?? hint?.name ?? "dom"
    const capabilities = ["hover", "pin", "highlight", "errors", "console", "network"]
    if (registeredResolvers().length > 0) capabilities.push("source")
    return {
      type: "hello",
      token: config.token ?? null,
      app: {
        name: config.app?.name ?? location.host,
        kind: "web",
        url: `${location.origin}${location.pathname}`,
        bundleId: null,
        pid: null,
        framework: {
          name,
          version: detected?.version ?? (hint?.name === name ? hint?.version : null) ?? null,
          meta: hint?.meta ?? null,
        },
      },
      project: { root: config.projectRoot ?? null, gitBranch: config.gitBranch ?? null },
      sdk: { name: "@scout/web", version: VERSION },
      capabilities,
    }
  }

  const handle = (message: Incoming) => {
    switch (message.type) {
      case "session":
        setActive(message.active === true)
        break
      case "aim":
        setAim(message.active === true)
        break
      case "pin":
        void pin(message)
        break
      case "highlight":
        highlight(message)
        break
      case "resolve":
        bridge.send({ type: "error", id: message.id, code: "unsupported", message: "Web pages report hover and pin instead" })
        break
    }
  }

  const stopSignals = config.signals === false ? null : captureSignals(onSignal)
  const bridge = connectBridge({
    ports: config.port ? [config.port] : DEFAULT_PORTS,
    hello,
    onWelcome: (welcome) => setActive((welcome.session as { active?: unknown } | undefined)?.active === true),
    onMessage: handle,
    onDown: () => setActive(false),
  })

  return {
    get connected() {
      return bridge.ready
    },
    get active() {
      return active
    },
    stop() {
      bridge.close()
      setActive(false)
      stopSignals?.()
      overlay?.destroy()
      overlay = null
      onStop()
    },
  }
}
