#!/usr/bin/env node
import { createWriteStream, realpathSync, writeFileSync } from "node:fs"
import { createInterface } from "node:readline"
import { parseArgs } from "node:util"
import { fileURLToPath } from "node:url"
import { WebSocketServer } from "ws"

const LOOPBACK_HOST = /^(localhost|127\.0\.0\.1|\[::1\]|.+\.localhost)$/i
const CAPABILITIES = ["session", "aim", "pin", "highlight"]

function loopbackOrigin(origin) {
  if (!origin || origin === "null") return true
  try {
    return LOOPBACK_HOST.test(new URL(origin).hostname)
  } catch {
    return false
  }
}

export async function startMockBridge({
  port = 47811,
  host = "127.0.0.1",
  token = null,
  log = null,
  pinWindowMs = 2000,
  pinTimeoutMs = 220,
} = {}) {
  const server = new WebSocketServer({ host, port, verifyClient: ({ origin }) => loopbackOrigin(origin) })
  await new Promise((resolve, reject) => {
    server.once("listening", resolve)
    server.once("error", reject)
  })

  const records = []
  const listeners = new Set()
  const clients = new Map()
  const pendingPins = new Map()
  let session = false
  let aim = false
  let nextClient = 0
  let nextPin = 0

  const record = (dir, client, msg) => {
    const entry = { t: Date.now(), dir, client: client?.id ?? null, msg }
    records.push(entry)
    log?.write(`${JSON.stringify(entry)}\n`)
    listeners.forEach((listener) => listener(entry))
  }

  const send = (client, message) => {
    const framed = { v: 1, ...message }
    if (client.ws.readyState !== client.ws.OPEN) return
    client.ws.send(JSON.stringify(framed))
    record("out", client, framed)
  }

  const broadcast = (message) => {
    for (const client of clients.values()) if (client.hello) send(client, message)
  }

  server.on("connection", (ws, request) => {
    const client = { id: ++nextClient, ws, hello: null, lastHoverAt: 0, origin: request.headers.origin ?? null }
    clients.set(ws, client)
    record("open", client, { origin: client.origin })
    ws.on("message", (data) => {
      let message
      try {
        message = JSON.parse(String(data))
      } catch {
        send(client, { type: "error", code: "invalidRequest", message: "Frames must be JSON" })
        return
      }
      record("in", client, message)
      switch (message.type) {
        case "hello":
          if (token && message.token !== token) {
            send(client, { type: "error", code: "unauthorized", message: "Unknown token" })
            ws.close()
            return
          }
          client.hello = message
          send(client, { type: "welcome", scout: { version: "mock" }, session: { active: session }, capabilities: CAPABILITIES })
          if (aim) send(client, { type: "aim", active: true })
          break
        case "hover":
          client.lastHoverAt = Date.now()
          break
        case "pinned":
          pendingPins.get(message.id)?.(message)
          break
        case "context":
        case "signal":
          break
        default:
          send(client, { type: "error", id: message.id, code: "unsupported", message: `Unknown type ${message.type}` })
      }
    })
    ws.on("close", () => {
      clients.delete(ws)
      record("close", client, null)
    })
  })

  return {
    port,
    records,
    get clients() {
      return [...clients.values()]
    },
    setSession(active) {
      session = active
      if (!active) aim = false
      broadcast({ type: "session", active })
    },
    setAim(active) {
      aim = active
      broadcast({ type: "aim", active })
    },
    async pin({ at = Date.now(), timeoutMs = pinTimeoutMs } = {}) {
      const target = [...clients.values()]
        .filter((client) => client.hello && Date.now() - client.lastHoverAt <= pinWindowMs)
        .sort((a, b) => b.lastHoverAt - a.lastHoverAt)[0]
      if (!target) return { id: null, reply: null, elapsedMs: 0 }
      const id = `pin-${++nextPin}`
      const started = Date.now()
      const reply = await new Promise((resolve) => {
        const timer = setTimeout(() => resolve(null), timeoutMs)
        pendingPins.set(id, (message) => {
          clearTimeout(timer)
          resolve(message)
        })
        send(target, { type: "pin", id, at })
      })
      pendingPins.delete(id)
      return { id, reply, elapsedMs: Date.now() - started }
    },
    highlight(target, style = "beam", durationMs = 1500) {
      broadcast({ type: "highlight", ...target, style, durationMs })
    },
    broadcast,
    waitFor(predicate, { timeoutMs = 5000, from = 0 } = {}) {
      const existing = records.slice(from).find(predicate)
      if (existing) return Promise.resolve(existing)
      return new Promise((resolve, reject) => {
        const listener = (entry) => {
          if (!predicate(entry)) return
          cleanup()
          resolve(entry)
        }
        const timer = setTimeout(() => {
          cleanup()
          reject(new Error(`No matching message within ${timeoutMs} ms`))
        }, timeoutMs)
        const cleanup = () => {
          clearTimeout(timer)
          listeners.delete(listener)
        }
        listeners.add(listener)
      })
    },
    close() {
      for (const client of clients.values()) client.ws.terminate()
      return new Promise((resolve) => server.close(() => resolve()))
    },
  }
}

async function runCli() {
  const { values } = parseArgs({
    options: {
      port: { type: "string", default: process.env.SCOUT_BRIDGE_PORT ?? "47811" },
      token: { type: "string" },
      log: { type: "string" },
      "bridge-file": { type: "string" },
    },
  })
  const log = values.log ? createWriteStream(values.log, { flags: "a" }) : process.stdout
  const bridge = await startMockBridge({ port: Number(values.port), token: values.token ?? null, log })
  if (values["bridge-file"]) {
    writeFileSync(values["bridge-file"], JSON.stringify({ port: bridge.port, token: values.token ?? null, pid: process.pid, protocol: 1 }))
  }
  process.stderr.write(
    `mock Scout bridge on ws://127.0.0.1:${bridge.port}/v1\n` +
      "commands: session on|off, aim on|off, pin, highlight <selector> [beam|flare] [ms], or a raw JSON message\n",
  )
  const lines = createInterface({ input: process.stdin })
  for await (const line of lines) {
    const [command, ...args] = line.trim().split(/\s+/)
    if (!command) continue
    if (command === "session") bridge.setSession(args[0] !== "off")
    else if (command === "aim") bridge.setAim(args[0] !== "off")
    else if (command === "pin") {
      const { id, reply, elapsedMs } = await bridge.pin()
      process.stderr.write(id ? `${id}: ${reply ? "pinned" : "no reply"} in ${elapsedMs} ms\n` : "pin: no client hovered in the last 2 s\n")
    } else if (command === "highlight") bridge.highlight({ selector: args[0] }, args[1] ?? "beam", Number(args[2] ?? 1500))
    else {
      try {
        bridge.broadcast(JSON.parse(line))
      } catch {
        process.stderr.write(`unknown command: ${line}\n`)
      }
    }
  }
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  runCli().catch((error) => {
    process.stderr.write(`${error.message}\n`)
    process.exit(1)
  })
}
