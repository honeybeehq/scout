import { build } from "esbuild"
import { execFileSync } from "node:child_process"
import { readFileSync, rmSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { gzipSync } from "node:zlib"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const packages = join(root, "packages")
const tsc = join(root, "node_modules/.bin/tsc")

function clean(name) {
  rmSync(join(packages, name, "dist"), { recursive: true, force: true })
}

function declarations(name) {
  execFileSync(tsc, ["-p", join(packages, name)], { stdio: "inherit" })
}

const browser = { bundle: true, format: "esm", platform: "browser", target: "es2022", logLevel: "warning" }

clean("web")
await build({ ...browser, entryPoints: [join(packages, "web/src/index.ts")], outfile: join(packages, "web/dist/index.js") })
await build({
  ...browser,
  entryPoints: [join(packages, "web/src/index.ts")],
  outfile: join(packages, "web/dist/scout.global.js"),
  format: "iife",
  globalName: "Scout",
  minify: true,
})
declarations("web")

clean("react")
await build({
  ...browser,
  entryPoints: [join(packages, "react/src/index.ts")],
  outfile: join(packages, "react/dist/index.js"),
  external: ["@scout/web"],
})
declarations("react")

clean("vite")
await build({
  bundle: true,
  format: "esm",
  platform: "node",
  target: "node20",
  logLevel: "warning",
  packages: "external",
  entryPoints: [join(packages, "vite/src/index.ts")],
  outfile: join(packages, "vite/dist/index.js"),
})
declarations("vite")

const minifiedReact = await build({
  ...browser,
  entryPoints: [join(packages, "react/src/index.ts")],
  external: ["@scout/web"],
  minify: true,
  write: false,
})
const kb = (bytes) => `${(bytes / 1024).toFixed(1)} kB`
const core = readFileSync(join(packages, "web/dist/scout.global.js"))
const react = minifiedReact.outputFiles[0].contents
console.log(`@scout/web   ${kb(core.length)} min, ${kb(gzipSync(core).length)} min+gz`)
console.log(`@scout/react ${kb(react.length)} min, ${kb(gzipSync(react).length)} min+gz`)
