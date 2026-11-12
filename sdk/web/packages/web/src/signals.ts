import { clip } from "./aria"
import { stripQuery } from "./paths"

export interface SignalRecord {
  at: number
  kind: "error" | "console" | "network" | "perf"
  message: string
  stack?: string | undefined
  level?: "warn" | "error"
  method?: string
  url?: string
  status?: number
  sent?: boolean
}

const MAX_MESSAGE = 1000

function describeValue(value: unknown): string {
  if (typeof value === "string") return value
  if (value instanceof Error) return `${value.name}: ${value.message}`
  if (typeof value === "function") return `[function ${value.name || "anonymous"}]`
  if (value === null || typeof value !== "object") return String(value)
  if (Array.isArray(value)) return `[array(${value.length})]`
  if (typeof Element !== "undefined" && value instanceof Element) return `<${value.localName}>`
  const keys = Object.keys(value)
  return `{${keys.slice(0, 8).join(", ")}${keys.length > 8 ? ", …" : ""}}`
}

function formatConsole(args: unknown[]): string {
  const rest = [...args]
  let head = ""
  if (typeof rest[0] === "string") {
    head = (rest.shift() as string).replace(/%[sdifoOc%]/g, (token) => {
      if (token === "%%") return "%"
      if (rest.length === 0) return token
      const value = rest.shift()
      return token === "%c" ? "" : describeValue(value)
    })
  }
  return clip([head, ...rest.map(describeValue)].join(" "), MAX_MESSAGE) ?? ""
}

function cleanUrl(raw: string): string {
  try {
    const url = new URL(raw, location.href)
    return url.origin === location.origin ? url.pathname : `${url.origin}${url.pathname}`
  } catch {
    return stripQuery(raw)
  }
}

export function captureSignals(push: (record: SignalRecord) => void): () => void {
  const cleanups: Array<() => void> = []
  let busy = false

  const record = (signal: Omit<SignalRecord, "at">) => {
    if (busy) return
    busy = true
    try {
      push({ at: Date.now(), ...signal })
    } catch {
      return
    } finally {
      busy = false
    }
  }

  const network = (method: string, rawUrl: string, status: number, error?: unknown) => {
    const url = cleanUrl(rawUrl)
    const outcome = status ? String(status) : `failed${error ? `: ${describeValue(error)}` : ""}`
    record({ kind: "network", method, url, status, message: `${method} ${url} ${outcome}` })
  }

  const onError = (event: ErrorEvent) => {
    const error: unknown = event.error
    const message = error instanceof Error ? `${error.name}: ${error.message}` : event.message || "Script error"
    record({ kind: "error", message: clip(message, MAX_MESSAGE) ?? "", stack: error instanceof Error ? error.stack : undefined })
  }

  const onRejection = (event: PromiseRejectionEvent) => {
    const reason: unknown = event.reason
    record({
      kind: "error",
      message: clip(`Unhandled rejection: ${describeValue(reason)}`, MAX_MESSAGE) ?? "",
      stack: reason instanceof Error ? reason.stack : undefined,
    })
  }

  addEventListener("error", onError)
  addEventListener("unhandledrejection", onRejection)
  cleanups.push(() => {
    removeEventListener("error", onError)
    removeEventListener("unhandledrejection", onRejection)
  })

  for (const level of ["warn", "error"] as const) {
    const original = console[level]
    const wrapped = function (this: Console, ...args: unknown[]) {
      const error = args.find((arg): arg is Error => arg instanceof Error)
      record({ kind: "console", level, message: formatConsole(args), stack: error?.stack })
      return original.apply(this, args)
    }
    console[level] = wrapped
    cleanups.push(() => {
      if (console[level] === wrapped) console[level] = original
    })
  }

  const nativeFetch = globalThis.fetch
  if (typeof nativeFetch === "function") {
    const wrappedFetch = function (input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
      const request = typeof Request !== "undefined" && input instanceof Request ? input : null
      const method = (init?.method ?? request?.method ?? "GET").toUpperCase()
      const url = request ? request.url : String(input)
      return nativeFetch(input, init).then(
        (response) => {
          if (!response.ok && response.type !== "opaque" && response.type !== "opaqueredirect") {
            network(method, url, response.status)
          }
          return response
        },
        (error: unknown) => {
          if ((error as Error | null)?.name !== "AbortError") network(method, url, 0, error)
          throw error
        },
      )
    }
    globalThis.fetch = wrappedFetch
    cleanups.push(() => {
      if (globalThis.fetch === wrappedFetch) globalThis.fetch = nativeFetch
    })
  }

  if (typeof XMLHttpRequest !== "undefined") {
    const proto = XMLHttpRequest.prototype
    const open = proto.open
    const send = proto.send
    const requests = new WeakMap<XMLHttpRequest, { method: string; url: string }>()
    proto.open = function (this: XMLHttpRequest, ...args: unknown[]) {
      requests.set(this, { method: String(args[0]).toUpperCase(), url: String(args[1]) })
      return (open as (...rest: unknown[]) => void).apply(this, args)
    } as typeof proto.open
    proto.send = function (this: XMLHttpRequest, body?: Document | XMLHttpRequestBodyInit | null) {
      const request = requests.get(this)
      if (request) {
        let aborted = false
        this.addEventListener("abort", () => {
          aborted = true
        })
        this.addEventListener("loadend", () => {
          if (!aborted && (this.status === 0 || this.status >= 400)) network(request.method, request.url, this.status)
        })
      }
      return send.call(this, body)
    }
    cleanups.push(() => {
      proto.open = open
      proto.send = send
    })
  }

  let previous = 0
  let frame = 0
  const tick = (now: number) => {
    if (previous && document.visibilityState === "visible" && now - previous > 50) {
      record({ kind: "perf", message: `Frame hitch: ${Math.round(now - previous)} ms` })
    }
    previous = document.visibilityState === "visible" ? now : 0
    frame = requestAnimationFrame(tick)
  }
  frame = requestAnimationFrame(tick)
  cleanups.push(() => cancelAnimationFrame(frame))
  if (typeof PerformanceObserver !== "undefined" && PerformanceObserver.supportedEntryTypes.includes("longtask")) {
    const observer = new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) record({ kind: "perf", message: `Long task: ${Math.round(entry.duration)} ms` })
    })
    observer.observe({ type: "longtask" })
    cleanups.push(() => observer.disconnect())
  }

  return () => cleanups.forEach((cleanup) => cleanup())
}
