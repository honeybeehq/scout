import { execFileSync } from "node:child_process"
import { readFileSync, realpathSync } from "node:fs"
import { createRequire } from "node:module"
import { homedir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"
import { version as viteVersion, type Plugin } from "vite"

export interface ScoutViteOptions {
  app?: { name?: string }
  props?: "off" | "safe"
  bridgeFile?: string
  enabled?: boolean
}

interface FrameworkHint {
  name: string
  version: string | null
}

const VIRTUAL_ID = "virtual:scout"
const RESOLVED_ID = `\0${VIRTUAL_ID}`
const BROWSER_PATH = `/@id/__x00__${VIRTUAL_ID}`
const FRAMEWORKS = ["react", "preact", "vue", "svelte", "solid-js"]
const ADAPTERS = ["@scout/react"]

function readJson(path: string): Record<string, unknown> | null {
  try {
    return JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>
  } catch {
    return null
  }
}

function bridgeFile(options: ScoutViteOptions): string {
  return options.bridgeFile
    ?? process.env.SCOUT_BRIDGE_FILE
    ?? join(homedir(), "Library", "Application Support", "Scout", "bridge.json")
}

function readBridge(path: string): { port?: number; token?: string } {
  const data = readJson(path)
  const port = data?.port
  const token = data?.token
  return {
    ...(typeof port === "number" && Number.isInteger(port) ? { port } : {}),
    ...(typeof token === "string" && token ? { token } : {}),
  }
}

function git(cwd: string, args: string[]): string | null {
  try {
    return execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim() || null
  } catch {
    return null
  }
}

function frameworkHint(root: string): FrameworkHint | null {
  const manifest = readJson(join(root, "package.json"))
  if (!manifest) return null
  const dependencies = {
    ...(manifest.peerDependencies as object | undefined),
    ...(manifest.devDependencies as object | undefined),
    ...(manifest.dependencies as object | undefined),
  }
  const name = FRAMEWORKS.find((candidate) => candidate in dependencies)
  if (!name) return null
  let version: string | null = null
  try {
    const require = createRequire(join(root, "package.json"))
    const installed = readJson(require.resolve(`${name}/package.json`))?.version
    version = typeof installed === "string" ? installed : null
  } catch {
    version = null
  }
  return { name, version }
}

function inlineJson(value: unknown): string {
  return JSON.stringify(value).replace(/</g, "\\u003c")
}

export function scout(options: ScoutViteOptions = {}): Plugin {
  const webEntry = fileURLToPath(import.meta.resolve("@scout/web"))
  let enabled = false
  let serverRoot = ""
  let projectRoot = ""
  let appName: string | undefined
  let framework: FrameworkHint | null = null

  return {
    name: "scout",
    apply: "serve",
    config() {
      return { optimizeDeps: { exclude: ["@scout/web", ...ADAPTERS] } }
    },
    configResolved(config) {
      enabled = options.enabled ?? process.env.SCOUT_DISABLED !== "1"
      serverRoot = realpathSync(config.root)
      projectRoot = git(serverRoot, ["rev-parse", "--show-toplevel"]) ?? serverRoot
      framework = frameworkHint(serverRoot)
      const name = readJson(join(serverRoot, "package.json"))?.name
      appName = options.app?.name ?? (typeof name === "string" ? name : undefined)
    },
    resolveId(id, importer) {
      if (id === VIRTUAL_ID) return RESOLVED_ID
      if (importer === RESOLVED_ID && id === "@scout/web") return webEntry
      return null
    },
    async load(id) {
      if (id !== RESOLVED_ID) return null
      if (!enabled) return "export {}"
      const imports = [`import "@scout/web";`]
      for (const adapter of ADAPTERS) {
        const resolved = await this.resolve(adapter, join(serverRoot, "index.html"), { skipSelf: true })
        if (resolved) imports.push(`import ${JSON.stringify(resolved.id)};`)
      }
      return imports.join("\n")
    },
    transformIndexHtml: {
      order: "pre",
      handler() {
        if (!enabled) return
        const branch = git(serverRoot, ["rev-parse", "--abbrev-ref", "HEAD"])
        const config = {
          ...readBridge(bridgeFile(options)),
          projectRoot,
          serverRoot,
          gitBranch: branch && branch !== "HEAD" ? branch : null,
          app: appName ? { name: appName } : undefined,
          framework: { name: framework?.name, version: framework?.version ?? null, meta: `vite@${viteVersion}` },
          props: options.props ?? "off",
        }
        return [
          { tag: "script", children: `window.__SCOUT__=${inlineJson(config)}`, injectTo: "head-prepend" },
          { tag: "script", attrs: { type: "module", src: BROWSER_PATH }, injectTo: "head-prepend" },
        ]
      },
    },
  }
}

export default scout
