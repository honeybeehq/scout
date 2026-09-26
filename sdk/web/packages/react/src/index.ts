import {
  isLibraryPath,
  parseFrame,
  registerResolver,
  type ComponentInfo,
  type FrameworkResolver,
  type RawSource,
} from "@scout/web"

interface DebugSource {
  fileName?: string
  lineNumber?: number
  columnNumber?: number
}

type DebugStack = { stack?: unknown } | string | null | undefined

interface FiberLike {
  tag?: number
  type?: unknown
  name?: unknown
  return?: FiberLike | null
  memoizedProps?: unknown
  _debugOwner?: FiberLike | null
  owner?: FiberLike | null
  _debugSource?: DebugSource | null
  _debugStack?: DebugStack
  debugStack?: DebugStack
}

interface DevToolsHook {
  renderers?: Map<unknown, { version?: unknown }>
}

const COMPONENT_TAGS = new Set([0, 1, 11, 14, 15])
const MAX_OWNERS = 12
const MAX_STACK = 8
const FRAMEWORK_INTERNALS = new Set([
  "AppRouter", "Router", "OuterLayoutRouter", "InnerLayoutRouter", "LoadingBoundary", "ErrorBoundaryHandler",
  "RedirectBoundary", "RedirectErrorBoundary", "HTTPAccessFallbackBoundary", "HTTPAccessFallbackErrorBoundary",
  "RenderFromTemplateContext", "ScrollAndFocusHandler", "SegmentViewNode", "HotReload", "DevRootHTTPAccessFallbackBoundary",
])
const ROOT_KEYS = /^(__reactContainer\$|_reactRootContainer|__reactFiber\$)/

function fiberOf(element: Element): FiberLike | null {
  const record = element as unknown as Record<string, FiberLike | undefined>
  for (const key of Object.keys(element)) {
    if (key.startsWith("__reactFiber$") || key.startsWith("__reactInternalInstance$")) return record[key] ?? null
  }
  return null
}

function nameOf(type: unknown): string | null {
  if (typeof type === "function") {
    const fn = type as { displayName?: string; name?: string }
    return fn.displayName || fn.name || null
  }
  if (type && typeof type === "object") {
    const wrapper = type as { displayName?: string; render?: unknown; type?: unknown }
    return wrapper.displayName || nameOf(wrapper.render) || nameOf(wrapper.type)
  }
  return null
}

function ownerName(node: FiberLike): string | null {
  return nameOf(node.type) ?? (typeof node.name === "string" ? node.name : null)
}

function ownerOf(node: FiberLike): FiberLike | null {
  return node._debugOwner ?? node.owner ?? null
}

function parentComponent(node: FiberLike): FiberLike | null {
  for (let current = node.return ?? null; current; current = current.return ?? null) {
    if (current.tag !== undefined && COMPONENT_TAGS.has(current.tag)) return current
  }
  return null
}

function stackText(node: FiberLike): string | null {
  const value = node._debugStack ?? node.debugStack
  if (typeof value === "string") return value
  try {
    return typeof value?.stack === "string" ? value.stack : null
  } catch {
    return null
  }
}

function sourceOf(node: FiberLike): RawSource | null {
  const debug = node._debugSource
  if (debug?.fileName && !isLibraryPath(debug.fileName)) {
    return { url: debug.fileName, line: debug.lineNumber ?? 1, column: debug.columnNumber ?? null, generated: false }
  }
  const stack = stackText(node)
  if (!stack) return null
  for (const line of stack.split("\n")) {
    const frame = parseFrame(line)
    if (frame && !isLibraryPath(frame.url)) {
      return { url: frame.url, line: frame.line, column: frame.column, generated: true }
    }
  }
  return null
}

function names(start: FiberLike | null, next: (node: FiberLike) => FiberLike | null): string[] {
  const found: string[] = []
  for (let node = start, hops = 0; node && hops < MAX_OWNERS * 4 && found.length < MAX_OWNERS; node = next(node), hops += 1) {
    const name = ownerName(node)
    if (name && !FRAMEWORK_INTERNALS.has(name)) found.push(name)
  }
  return found
}

function resolve(element: Element): ComponentInfo | null {
  const host = fiberOf(element)
  if (!host) return null
  let source: RawSource | null = null
  let owner: FiberLike | null = ownerOf(host)
  let node: FiberLike | null = host
  for (let hops = 0; node && hops < MAX_OWNERS; hops += 1, node = ownerOf(node)) {
    source = sourceOf(node)
    if (source) {
      owner = ownerOf(node)
      break
    }
  }
  const tracksOwners = "_debugOwner" in host
  const chain = tracksOwners ? names(owner, ownerOf) : names(parentComponent(host), parentComponent)
  const componentFiber = tracksOwners ? owner : parentComponent(host)
  return {
    component: chain[0] ?? null,
    ownerStack: chain.slice(0, MAX_STACK).reverse(),
    source,
    props: componentFiber?.memoizedProps,
  }
}

function hasReactRoot(): boolean {
  const candidates: Array<object | null> = [document, document.documentElement, document.body]
  for (const child of Array.from(document.body?.children ?? []).slice(0, 20)) candidates.push(child)
  return candidates.some((node) => !!node && Object.keys(node).some((key) => ROOT_KEYS.test(key)))
}

function detect(): { version: string | null } | null {
  let version: string | null = null
  try {
    const hook = (globalThis as { __REACT_DEVTOOLS_GLOBAL_HOOK__?: DevToolsHook }).__REACT_DEVTOOLS_GLOBAL_HOOK__
    for (const renderer of hook?.renderers?.values() ?? []) {
      if (typeof renderer?.version === "string") {
        version = renderer.version
        break
      }
    }
  } catch {
    version = null
  }
  return version || hasReactRoot() ? { version } : null
}

export const reactResolver: FrameworkResolver = { name: "react", detect, resolve }

registerResolver(reactResolver)
