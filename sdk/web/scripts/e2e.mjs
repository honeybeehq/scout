#!/usr/bin/env node
import { execFileSync, spawn } from "node:child_process"
import { randomUUID } from "node:crypto"
import { mkdtempSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs"
import { createServer } from "node:net"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { chromium } from "playwright"
import { startMockBridge } from "./mock-bridge.mjs"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const fixture = join(root, "fixtures/react-vite")
const vite = join(fixture, "node_modules/.bin/vite")
const bridgePort = Number(process.env.SCOUT_E2E_PORT ?? 47819)
const token = `e2e-${randomUUID()}`
const scratch = mkdtempSync(join(tmpdir(), "scout-e2e-"))
const typedEmail = "e2e-secret@example.com"
const results = []

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
const incoming = (type) => (entry) => entry.dir === "in" && entry.msg?.type === type

function lineOf(file, needle) {
  return readFileSync(join(fixture, file), "utf8").split("\n").findIndex((line) => line.includes(needle)) + 1
}

function freePort() {
  return new Promise((resolve, reject) => {
    const server = createServer()
    server.once("error", reject)
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address()
      server.close(() => resolve(port))
    })
  })
}

function assert(condition, message) {
  if (!condition) throw new Error(message)
}

async function step(name, run) {
  try {
    const detail = await run()
    results.push({ name, pass: true, detail: detail ?? "" })
  } catch (error) {
    results.push({ name, pass: false, detail: error.message })
  }
}

function printResults() {
  const width = Math.max(...results.map((result) => result.name.length))
  console.log(`\n${"RESULT".padEnd(6)}  ${"CHECK".padEnd(width)}  DETAIL`)
  for (const { name, pass, detail } of results) {
    console.log(`${(pass ? "PASS" : "FAIL").padEnd(6)}  ${name.padEnd(width)}  ${detail}`)
  }
  const failed = results.filter((result) => !result.pass).length
  console.log(`\n${results.length - failed}/${results.length} passed`)
  return failed
}

function startDevServer(port, env) {
  const child = spawn(vite, ["--port", String(port), "--strictPort", "--host", "127.0.0.1"], {
    cwd: fixture,
    env: { ...process.env, ...env, NO_COLOR: "1" },
    stdio: ["ignore", "pipe", "pipe"],
  })
  let output = ""
  const ready = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`vite did not start:\n${output}`)), 30_000)
    const onData = (chunk) => {
      output += String(chunk).replace(/\x1b\[[0-9;]*m/g, "")
      if (output.includes(`127.0.0.1:${port}`)) {
        clearTimeout(timer)
        resolve()
      }
    }
    child.stdout.on("data", onData)
    child.stderr.on("data", onData)
    child.once("exit", (code) => reject(new Error(`vite exited with ${code}:\n${output}`)))
  })
  return { child, ready }
}

async function center(page, selector) {
  const box = await page.locator(selector).first().boundingBox()
  assert(box, `${selector} is not visible`)
  return { x: box.x + box.width / 2, y: box.y + box.height / 2, box }
}

async function moveTo(page, selector, steps = 6) {
  const { x, y, box } = await center(page, selector)
  await page.mouse.move(x, y, { steps })
  return box
}

async function sweep(page, selectors, durationMs, pauseMs) {
  const points = []
  for (const selector of selectors) points.push(await center(page, selector))
  const until = Date.now() + durationMs
  for (let index = 0; Date.now() < until; index += 1) {
    const point = points[index % points.length]
    await page.mouse.move(point.x, point.y, { steps: 2 })
    await sleep(pauseMs)
  }
}

function minGap(entries) {
  let gap = Infinity
  for (let index = 1; index < entries.length; index += 1) gap = Math.min(gap, entries[index].t - entries[index - 1].t)
  return gap
}

function scanForScout(directory) {
  const markers = ["__SCOUT__", "scout-overlay", "@scout/", "scout.resolvers", "scout.web.instance", "virtual:scout", "47811"]
  const hits = []
  const walk = (path) => {
    for (const name of readdirSync(path)) {
      const full = join(path, name)
      if (statSync(full).isDirectory()) walk(full)
      else {
        const text = readFileSync(full, "utf8")
        for (const marker of markers) if (text.includes(marker)) hits.push(`${name}: ${marker}`)
      }
    }
  }
  walk(directory)
  return hits
}

async function main() {
  if (!process.argv.includes("--no-build")) execFileSync("node", [join(root, "scripts/build.mjs")], { stdio: "inherit" })

  const gitRoot = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: fixture, encoding: "utf8" }).trim()
  const payLine = lineOf("src/checkout/PayButton.tsx", "<button")
  const throwLine = lineOf("src/checkout/PaymentForm.tsx", "throw new Error")
  const logFile = join(scratch, "bridge.jsonl")
  const bridgeFile = join(scratch, "bridge.json")
  const log = (await import("node:fs")).createWriteStream(logFile)

  let bridge
  try {
    bridge = await startMockBridge({ port: bridgePort, token, log })
  } catch (error) {
    throw new Error(`Cannot listen on 127.0.0.1:${bridgePort} (${error.code ?? error.message}). Set SCOUT_E2E_PORT to a free port.`)
  }
  writeFileSync(bridgeFile, JSON.stringify({ port: bridgePort, token, pid: process.pid, protocol: 1 }))

  const devPort = await freePort()
  const server = startDevServer(devPort, { SCOUT_BRIDGE_FILE: bridgeFile })
  const browser = await chromium.launch()
  const pageErrors = []
  try {
    await server.ready
    const page = await browser.newPage({ viewport: { width: 1200, height: 800 } })
    page.on("pageerror", (error) => pageErrors.push(error.message))
    const origin = `http://127.0.0.1:${devPort}`
    await page.goto(`${origin}/checkout?utm=e2e#top`)
    await page.waitForSelector("[data-testid=pay-now]")

    let hello
    await step("hello: project root, framework, token", async () => {
      hello = (await bridge.waitFor(incoming("hello"), { timeoutMs: 10_000 })).msg
      assert(hello.project?.root === gitRoot, `project.root ${hello.project?.root} != ${gitRoot}`)
      assert(hello.app?.framework?.name === "react", `framework ${JSON.stringify(hello.app?.framework)}`)
      assert(hello.token === token, "token was not forwarded from bridge.json")
      assert(hello.app?.url === `${origin}/checkout`, `app.url ${hello.app?.url}`)
      return `root=${hello.project.root} framework=${hello.app.framework.name}@${hello.app.framework.version} meta=${hello.app.framework.meta} branch=${hello.project.gitBranch}`
    })

    await step("idle: nothing streamed before session", async () => {
      const from = bridge.records.length
      await moveTo(page, "[data-testid=pay-now]")
      await moveTo(page, "input[name=email]")
      await moveTo(page, "[data-testid=order-summary]")
      await page.getByRole("button", { name: "Break checkout" }).click()
      await sleep(800)
      const sent = bridge.records.slice(from).filter((entry) => entry.dir === "in").map((entry) => entry.msg.type)
      assert(sent.length === 0, `sent while idle: ${sent.join(", ")}`)
      return "0 messages after hover + error while idle"
    })

    await step("session on: context arrives", async () => {
      const from = bridge.records.length
      bridge.setSession(true)
      const { msg } = await bridge.waitFor(incoming("context"), { from })
      assert(msg.route === "/checkout", `route ${msg.route}`)
      assert(msg.url === `${origin}/checkout`, `url ${msg.url}`)
      return `route=${msg.route} url=${msg.url} title=${msg.title}`
    })

    await step("session on: idle error replayed (≤30 s old)", async () => {
      const { msg } = await bridge.waitFor(
        (entry) => incoming("signal")(entry) && entry.msg.kind === "error",
        { timeoutMs: 3000 },
      )
      assert(msg.message.includes("Checkout exploded"), msg.message)
      return msg.message
    })

    await step("session on: resting pointer reported without moving", async () => {
      const { msg } = await bridge.waitFor(
        (entry) => incoming("hover")(entry) && entry.msg.element?.label === "Break checkout",
        { timeoutMs: 3000 },
      )
      return `${msg.element.role} "${msg.element.label}" · ${msg.element.source?.file.split("/").pop()}:${msg.element.source?.line}`
    })

    let payHover
    await step("hover Pay now: role, label, component, source", async () => {
      const from = bridge.records.length
      const box = await moveTo(page, "[data-testid=pay-now]")
      payHover = (await bridge.waitFor(
        (entry) => incoming("hover")(entry) && entry.msg.element?.testId === "pay-now",
        { from, timeoutMs: 3000 },
      )).msg
      const element = payHover.element
      assert(element.role === "button", `role ${element.role}`)
      assert(element.label === "Pay now", `label ${element.label}`)
      assert(element.component === "PayButton", `component ${element.component}`)
      assert(element.ownerStack.at(-1) === "PayButton" && element.ownerStack[0] === "App", `ownerStack ${element.ownerStack}`)
      assert(element.source?.file === "sdk/web/fixtures/react-vite/src/checkout/PayButton.tsx", `file ${element.source?.file}`)
      assert(element.source.line === payLine, `line ${element.source.line}, expected ${payLine}`)
      assert(element.selector === '[data-testid="pay-now"]', `selector ${element.selector}`)
      assert(Math.abs(element.bounds.x - box.x) < 1 && Math.abs(element.bounds.width - box.width) < 1, "bounds mismatch")
      assert(element.bounds.space === "viewport" && payHover.viewport, "viewport origin missing")
      assert(element.props === null, "props must be null by default")
      return `${element.role} "${element.label}" · ${element.component} · ${element.source.file}:${element.source.line}:${element.source.column} · [${element.ownerStack.join(" > ")}]`
    })

    await step("hover rate ≤ 4 Hz while active", async () => {
      const from = bridge.records.length
      await sweep(page, ["[data-testid=pay-now]", "input[name=email]", "h1", "[data-testid=order-summary] h2"], 2000, 30)
      await sleep(400)
      const hovers = bridge.records.slice(from).filter(incoming("hover"))
      assert(hovers.length >= 3, `only ${hovers.length} hovers`)
      const gap = minGap(hovers)
      assert(gap >= 200, `min gap ${gap} ms`)
      return `${hovers.length} hovers in 2 s, min gap ${gap} ms`
    })

    await step("email field: label, no input value", async () => {
      await page.locator("input[name=email]").fill(typedEmail)
      const from = bridge.records.length
      await moveTo(page, "h1")
      await sleep(300)
      await moveTo(page, "input[name=email]")
      const { msg } = await bridge.waitFor(
        (entry) => incoming("hover")(entry) && entry.msg.element?.role === "textbox",
        { from, timeoutMs: 3000 },
      )
      assert(msg.element.label === "Email", `label ${msg.element.label}`)
      assert(msg.element.text === null, `text ${msg.element.text}`)
      assert(msg.element.state.focused === true, "focus state not reported")
      return `textbox "${msg.element.label}" focused=${msg.element.state.focused}`
    })

    await step("aim on: overlay outline in shadow root", async () => {
      await moveTo(page, "[data-testid=pay-now]")
      await sleep(300)
      bridge.setAim(true)
      await sleep(250)
      const overlay = await page.evaluate(() => {
        const host = document.querySelector("scout-overlay")
        const box = host?.shadowRoot?.querySelector('[data-box="aim"]')
        if (!box) return null
        const style = getComputedStyle(box)
        const rect = box.getBoundingClientRect()
        const target = document.querySelector("[data-testid=pay-now]").getBoundingClientRect()
        return {
          chip: box.textContent,
          border: style.borderTopColor,
          pointerEvents: getComputedStyle(host).pointerEvents,
          dx: Math.abs(rect.x - target.x),
          dw: Math.abs(rect.width - target.width),
        }
      })
      assert(overlay, "no aim box in scout-overlay shadow root")
      assert(overlay.border === "rgb(255, 106, 61)", `border ${overlay.border}`)
      assert(overlay.pointerEvents === "none", "overlay intercepts pointer events")
      assert(overlay.dx < 1 && overlay.dw < 1, "outline does not match the element")
      assert(overlay.chip.includes('"Pay now"') && overlay.chip.includes("PayButton.tsx"), `chip ${overlay.chip}`)
      return `chip: ${overlay.chip}`
    })

    await step("hover rate ≤ 20 Hz while aiming", async () => {
      const from = bridge.records.length
      await sweep(page, ["[data-testid=pay-now]", "input[name=email]", "h1", "[data-testid=order-summary] h2"], 1500, 20)
      await sleep(300)
      const hovers = bridge.records.slice(from).filter(incoming("hover"))
      const gap = minGap(hovers)
      assert(hovers.length >= 8, `only ${hovers.length} hovers`)
      assert(gap >= 40, `min gap ${gap} ms`)
      return `${hovers.length} hovers in 1.5 s, min gap ${gap} ms`
    })

    await step("pin: pinned with the hovered element within 220 ms", async () => {
      await moveTo(page, "[data-testid=pay-now]")
      await sleep(300)
      const { id, reply, elapsedMs } = await bridge.pin()
      assert(id, "mock bridge had no recently hovering client")
      assert(reply, "no pinned reply within 220 ms")
      assert(reply.id === id, `id ${reply.id}`)
      assert(reply.element?.id === payHover.element.id, `element ${reply.element?.id} != ${payHover.element.id}`)
      assert(reply.element.source?.line === payLine, "pinned element lost its source")
      return `${id} -> ${reply.element.id} (${reply.element.label}) in ${elapsedMs} ms`
    })

    await step("aim held still: hover repeats so pins keep routing", async () => {
      const from = bridge.records.length
      await sleep(2500)
      const repeats = bridge.records.slice(from).filter(incoming("hover"))
      const { reply } = await bridge.pin()
      assert(repeats.length >= 2, `${repeats.length} repeats`)
      assert(reply?.element?.testId === "pay-now", "pin after 2.5 s still should resolve")
      return `${repeats.length} repeats in 2.5 s; pin resolved`
    })

    await step("aim off: outline removed", async () => {
      bridge.setAim(false)
      await sleep(200)
      const present = await page.evaluate(() => !!document.querySelector("scout-overlay")?.shadowRoot?.querySelector('[data-box="aim"]'))
      assert(!present, "aim box still present")
    })

    await step("highlight by element id (flare)", async () => {
      bridge.highlight({ elementId: payHover.element.id }, "flare", 800)
      await sleep(150)
      const color = await page.evaluate(() => {
        const box = document.querySelector("scout-overlay")?.shadowRoot?.querySelector('[data-box="flash"].flare')
        return box ? getComputedStyle(box).borderTopColor : null
      })
      assert(color === "rgb(255, 106, 61)", `flash color ${color}`)
      return color
    })

    await step("route change: context on pushState and popstate", async () => {
      await moveTo(page, "h1")
      let from = bridge.records.length
      await page.getByRole("button", { name: "Orders" }).click()
      const pushed = (await bridge.waitFor(incoming("context"), { from, timeoutMs: 3000 })).msg
      assert(pushed.route === "/orders" && pushed.url === `${origin}/orders`, `pushState context ${JSON.stringify(pushed)}`)
      assert(pushed.title === "Orders · Acme", `title ${pushed.title}`)
      from = bridge.records.length
      await page.goBack()
      const popped = (await bridge.waitFor(incoming("context"), { from, timeoutMs: 3000 })).msg
      assert(popped.route === "/checkout", `popstate route ${popped.route}`)
      return `${pushed.route} ("${pushed.title}") then ${popped.route}`
    })

    await step("error signal with symbolicated stack", async () => {
      const from = bridge.records.length
      await page.getByRole("button", { name: "Break checkout" }).click()
      const { msg } = await bridge.waitFor(
        (entry) => incoming("signal")(entry) && entry.msg.kind === "error",
        { from, timeoutMs: 3000 },
      )
      assert(msg.message.includes("Checkout exploded"), msg.message)
      const frame = `sdk/web/fixtures/react-vite/src/checkout/PaymentForm.tsx:${throwLine}:`
      assert(msg.stack?.includes(frame), `stack lacks ${frame}:\n${msg.stack}`)
      return `${msg.message} @ ${frame}`
    })

    await step("network signal: failed fetch without query", async () => {
      const from = bridge.records.length
      await page.getByRole("button", { name: "Apply promo" }).click()
      const { msg } = await bridge.waitFor(
        (entry) => incoming("signal")(entry) && entry.msg.kind === "network",
        { from, timeoutMs: 3000 },
      )
      assert(msg.method === "POST" && msg.status === 404 && msg.url === "/api/promo", JSON.stringify(msg))
      return msg.message
    })

    await step("session off: no hover when moving", async () => {
      bridge.setSession(false)
      await sleep(300)
      const from = bridge.records.length
      await sweep(page, ["[data-testid=pay-now]", "input[name=email]", "h1", "[data-testid=order-summary] h2"], 1500, 40)
      await sleep(500)
      const sent = bridge.records.slice(from).filter((entry) => entry.dir === "in").map((entry) => entry.msg.type)
      const overlay = await page.evaluate(() => !!document.querySelector("scout-overlay"))
      assert(sent.length === 0, `sent after session end: ${sent.join(", ")}`)
      assert(!overlay, "overlay still mounted")
      return "0 messages"
    })

    await step("privacy: no input values, query strings or secrets sent", async () => {
      const sent = JSON.stringify(bridge.records.filter((entry) => entry.dir === "in").map((entry) => entry.msg))
      for (const secret of [typedEmail, "SPRING-SECRET", "utm=e2e", "ref=nav", "#top", "#recent"]) {
        assert(!sent.includes(secret), `found ${secret}`)
      }
      return `${bridge.records.filter((entry) => entry.dir === "in").length} frames checked`
    })
  } finally {
    await browser.close()
    server.child.kill()
  }

  await step("vite build: bundle has no Scout SDK code", async () => {
    const outDir = join(scratch, "dist")
    execFileSync(vite, ["build", "--outDir", outDir, "--emptyOutDir", "--logLevel", "error"], {
      cwd: fixture,
      env: { ...process.env, SCOUT_BRIDGE_FILE: bridgeFile },
      stdio: ["ignore", "ignore", "inherit"],
    })
    const hits = scanForScout(outDir)
    assert(hits.length === 0, hits.join(", "))
    return `${readdirSync(join(outDir, "assets")).length} assets scanned`
  })

  await bridge.close()
  log.end()
  const failed = printResults()
  console.log(`bridge log: ${logFile}`)
  if (pageErrors.length > 0) console.log(`page errors (expected: the fixture's throw button): ${[...new Set(pageErrors)].join(" | ")}`)
  process.exit(failed > 0 ? 1 : 0)
}

main().catch((error) => {
  console.error(error)
  printResults()
  process.exit(1)
})
