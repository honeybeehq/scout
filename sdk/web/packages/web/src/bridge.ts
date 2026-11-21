export type Incoming = { type: string; [key: string]: unknown }

export interface BridgeOptions {
  ports: number[]
  hello(): Record<string, unknown>
  onWelcome(message: Incoming): void
  onMessage(message: Incoming): void
  onDown(): void
}

export interface Bridge {
  readonly ready: boolean
  send(message: { type: string; [key: string]: unknown }): boolean
  close(): void
}

const MIN_DELAY_MS = 250
const FAST_MAX_DELAY_MS = 750
const SLOW_MAX_DELAY_MS = 2000
const FAST_WINDOW_MS = 30_000
const MAX_BUFFERED = 4_000_000

function decode(data: unknown): Incoming | null {
  if (typeof data !== "string") return null
  try {
    const message = JSON.parse(data) as Incoming
    return message && typeof message.type === "string" ? message : null
  } catch {
    return null
  }
}

export function connectBridge(options: BridgeOptions): Bridge {
  let ports = [...options.ports]
  let socket: WebSocket | null = null
  let ready = false
  let stopped = false
  let index = 0
  let fastUntil = FAST_WINDOW_MS
  let delay = MIN_DELAY_MS
  let timer: ReturnType<typeof setTimeout> | undefined

  const retry = (wasReady: boolean) => {
    if (stopped) return
    if (!wasReady && index < ports.length - 1) {
      index += 1
      open()
      return
    }
    index = 0
    const cap = performance.now() < fastUntil ? FAST_MAX_DELAY_MS : SLOW_MAX_DELAY_MS
    timer = setTimeout(open, Math.min(delay, cap) * (0.8 + Math.random() * 0.4))
    delay = Math.min(delay * 2, cap)
  }

  function open() {
    timer = undefined
    if (stopped || socket) return
    const port = ports[index]!
    let ws: WebSocket
    try {
      ws = new WebSocket(`ws://127.0.0.1:${port}/v1`)
    } catch {
      retry(false)
      return
    }
    socket = ws
    ws.onopen = () => ws.send(JSON.stringify({ v: 1, ...options.hello() }))
    ws.onmessage = (event) => {
      const message = decode(event.data)
      if (!message) return
      if (message.type === "welcome") {
        ready = true
        delay = MIN_DELAY_MS
        ports = [port, ...ports.filter((candidate) => candidate !== port)]
        index = 0
        options.onWelcome(message)
      } else if (message.type === "error" && message.code === "unauthorized") {
        stopped = true
        ws.close()
      } else if (ready) {
        options.onMessage(message)
      }
    }
    ws.onclose = () => {
      if (socket !== ws) return
      socket = null
      const wasReady = ready
      ready = false
      if (wasReady) options.onDown()
      retry(wasReady)
    }
  }

  const wake = () => {
    fastUntil = performance.now() + FAST_WINDOW_MS
    if (stopped || ready || socket) return
    clearTimeout(timer)
    timer = undefined
    index = 0
    delay = MIN_DELAY_MS
    open()
  }
  const onVisibility = () => { if (document.visibilityState === "visible") wake() }
  window.addEventListener("focus", wake)
  document.addEventListener("visibilitychange", onVisibility)

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", open, { once: true })
  else open()

  return {
    get ready() {
      return ready
    },
    send(message) {
      if (!ready || !socket || socket.readyState !== WebSocket.OPEN || socket.bufferedAmount > MAX_BUFFERED) return false
      socket.send(JSON.stringify({ v: 1, ...message }))
      return true
    },
    close() {
      stopped = true
      clearTimeout(timer)
      document.removeEventListener("DOMContentLoaded", open)
      window.removeEventListener("focus", wake)
      document.removeEventListener("visibilitychange", onVisibility)
      const current = socket
      socket = null
      if (ready) {
        ready = false
        options.onDown()
      }
      current?.close()
    },
  }
}
