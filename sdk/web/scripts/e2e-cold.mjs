import { spawn } from "node:child_process"
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { chromium } from "playwright"
import { startMockBridge } from "./mock-bridge.mjs"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const scratch = mkdtempSync(join(tmpdir(), "scout-cold-"))
const bridgeFile = join(scratch, "bridge.json")
const proof = join(root, "../../.audit/game")
const token = "cold-page-fixture"
const port = Number(process.env.SCOUT_COLD_PORT ?? 47817)
const devPort = Number(process.env.SCOUT_COLD_DEV_PORT ?? 5188)
writeFileSync(bridgeFile, JSON.stringify({ port, token }))
const server = spawn(join(root, "fixtures/react-vite/node_modules/.bin/vite"), ["--host", "127.0.0.1", "--port", String(devPort), "--strictPort"], {
  cwd: join(root, "fixtures/react-vite"), env: { ...process.env, SCOUT_BRIDGE_FILE: bridgeFile }, stdio: ["ignore", "pipe", "pipe"],
})
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
const attempts = []
let browser
let bridge
try {
  await new Promise((resolve, reject) => {
    server.stdout.on("data", (chunk) => { if (String(chunk).includes(`127.0.0.1:${devPort}`)) resolve() })
    server.on("exit", (code) => reject(new Error(`Vite exited ${code}`)))
    setTimeout(() => reject(new Error("Vite readiness timeout")), 15000).unref()
  })
  browser = await chromium.launch()
  const page = await browser.newPage({ viewport: { width: 1200, height: 900 } })
  const loadedAt = Date.now()
  const coldFailure = new Promise((resolve) => {
    page.on("websocket", (ws) => {
      attempts.push(Date.now())
      ws.on("close", () => { if (Date.now() - loadedAt >= 30000) resolve() })
    })
  })
  await page.goto(`http://127.0.0.1:${devPort}/game.html?pointAt=asteroid&hitchEvery=2000`)
  await page.waitForFunction(() => document.querySelector("#status")?.textContent.includes("registered"))
  await Promise.race([coldFailure, sleep(45000).then(() => { throw new Error("No cold reconnect attempt after 30 seconds") })])
  const startedAt = Date.now()
  bridge = await startMockBridge({ port, token })
  bridge.setSession(true)
  await bridge.waitFor((entry) => entry.dir === "in" && entry.msg.type === "hello", { timeoutMs: 2500 })
  const connectedMs = Date.now() - startedAt
  await bridge.waitFor((entry) => entry.dir === "in" && entry.msg.type === "hover" && entry.msg.element?.game?.entity.id === "asteroid-17")
  await sleep(Math.max(0, 6000 - (Date.now() - startedAt)))
  const pin = await bridge.pin()
  if (pin.reply?.element?.game?.entity.id !== "asteroid-17") throw new Error("Cold-page pin missed the game entity")
  const state = (await bridge.waitFor((entry) => entry.dir === "in" && entry.msg.type === "gameState" && entry.msg.id === pin.id)).msg
  if (state.reason !== "pin" || state.game.save?.seed !== 42) throw new Error("Cold-page pin save missing")
  const result = { passed: true, pageColdMs: startedAt - loadedAt, connectedMs, pinAtMs: Date.now() - startedAt, namedPin: pin.reply.element.label, saveStatus: state.game.saveStatus }
  await page.evaluate((value) => { document.querySelector("#evidence").textContent = JSON.stringify(value, null, 2) }, result)
  mkdirSync(proof, { recursive: true })
  await page.screenshot({ path: join(proof, "cold-page.png"), fullPage: true })
  await bridge.close()
  bridge = null
  await sleep(150)
  let from = attempts.length
  await page.evaluate(() => window.dispatchEvent(new Event("focus")))
  await sleep(400)
  if (attempts.length <= from) throw new Error("Focus did not retry immediately")
  await sleep(150)
  from = attempts.length
  await page.evaluate(() => document.dispatchEvent(new Event("visibilitychange")))
  await sleep(400)
  if (attempts.length <= from) throw new Error("Visible-page change did not retry immediately")
  console.log(JSON.stringify({ ...result, focusRetry: true, visibleRetry: true }, null, 2))
} finally {
  await browser?.close()
  server.kill()
  if (bridge) await bridge.close()
}
