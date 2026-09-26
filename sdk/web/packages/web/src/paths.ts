import type { PathRoots } from "./types"

const SCHEME = /^[a-z][a-z0-9+.-]*:/i
const FRAME = /([a-zA-Z][\w+.-]*:\/\/[^\s()]*|\/@fs\/[^\s()]*):(\d+):(\d+)/

export interface StackFrame {
  url: string
  line: number
  column: number
  start: number
  end: number
}

export function parseFrame(line: string): StackFrame | null {
  const match = FRAME.exec(line)
  if (!match) return null
  return {
    url: match[1]!,
    line: Number(match[2]),
    column: Number(match[3]),
    start: match.index,
    end: match.index + match[0].length,
  }
}

export function stripQuery(url: string): string {
  return url.replace(/[?#].*$/, "")
}

function within(path: string, base: string | undefined): base is string {
  return !!base && (path === base || path.startsWith(base.endsWith("/") ? base : `${base}/`))
}

function join(base: string, path: string): string {
  return `${base.replace(/\/+$/, "")}/${path.replace(/^\.?\/+/, "")}`
}

export function projectPath(raw: string, roots: PathRoots): string {
  const { projectRoot, serverRoot = projectRoot } = roots
  let path = raw.replace(/^webpack-internal:\/\/\//, "").replace(/^webpack:\/\/[^/]*\//, "")
  let served = false
  if (SCHEME.test(path)) {
    try {
      const url = new URL(path)
      served = url.protocol !== "file:"
      path = decodeURIComponent(url.pathname)
    } catch {
      return stripQuery(path)
    }
  }
  path = stripQuery(path)
  if (path.startsWith("/@fs/")) {
    path = path.slice(4)
    served = false
  }
  if (path.startsWith("./") && serverRoot) path = join(serverRoot, path)
  else if (served && serverRoot && !within(path, projectRoot) && !within(path, serverRoot)) path = join(serverRoot, path)
  if (within(path, projectRoot)) return path.slice(projectRoot.replace(/\/+$/, "").length + 1)
  return served || path.startsWith("./") ? path.replace(/^\.?\/+/, "") : path
}

export function isLibraryPath(url: string): boolean {
  return /\/node_modules\/|\/\.vite\/deps\/|\/@react-refresh|\/@vite\/client|react-dom|jsx-dev-runtime|jsx-runtime/.test(url)
}
