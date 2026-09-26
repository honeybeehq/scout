import { labelOf, roleOf, testIdOf, textOf } from "./aria"
import { frameOffset } from "./hit"
import { projectPath } from "./paths"
import { safeProps } from "./props"
import { registeredResolvers } from "./resolvers"
import { selectorOf } from "./selector"
import { originalPosition } from "./sourcemap"
import { settleWithin } from "./timing"
import type { Bounds, ComponentInfo, ElementDescriptor, PathRoots, PropsMode, RawSource, SourceLocation } from "./types"

const ids = new WeakMap<Element, string>()
const byId = new Map<string, WeakRef<Element>>()
const MAX_SOURCES = 500
let nextId = 0

export function idOf(element: Element): string {
  let id = ids.get(element)
  if (!id) {
    nextId += 1
    id = `e${nextId}`
    ids.set(element, id)
    if (byId.size > 5000) byId.forEach((ref, key) => ref.deref()?.isConnected || byId.delete(key))
    byId.set(id, new WeakRef(element))
  }
  return id
}

export function elementById(id: string): Element | null {
  const element = byId.get(id)?.deref()
  return element?.isConnected ? element : null
}

function round(value: number): number {
  return Math.round(value * 10) / 10
}

export function boundsOf(element: Element): Bounds {
  const rect = element.getBoundingClientRect()
  const offset = frameOffset(element.ownerDocument.defaultView)
  return {
    x: round(rect.left + offset.x),
    y: round(rect.top + offset.y),
    width: round(rect.width),
    height: round(rect.height),
    space: "viewport",
  }
}

function deepActiveElement(document: Document): Element | null {
  let active = document.activeElement
  while (active?.shadowRoot?.activeElement) active = active.shadowRoot.activeElement
  return active
}

function componentOf(element: Element): ComponentInfo | null {
  for (const resolver of registeredResolvers()) {
    try {
      const info = resolver.resolve(element)
      if (info) return info
    } catch {
      continue
    }
  }
  return null
}

export function createDescriber(roots: PathRoots, propsMode: PropsMode) {
  const sources = new Map<string, Promise<SourceLocation>>()

  function locate(raw: RawSource): Promise<SourceLocation> {
    const file = projectPath(raw.url, roots)
    if (!raw.generated) return Promise.resolve({ file, line: raw.line, column: raw.column })
    const key = `${raw.url}:${raw.line}:${raw.column}`
    let pending = sources.get(key)
    if (!pending) {
      if (sources.size >= MAX_SOURCES) sources.delete(sources.keys().next().value!)
      pending = originalPosition(raw.url, raw.line, raw.column ?? 1)
        .catch(() => null)
        .then((original) =>
          original
            ? { file: projectPath(original.url, roots), line: original.line, column: original.column }
            : { file, line: raw.line, column: raw.column },
        )
      sources.set(key, pending)
    }
    return pending
  }

  return async function describe(element: Element, sourceBudgetMs = 2000): Promise<ElementDescriptor> {
    const role = roleOf(element)
    const info = componentOf(element)
    const raw = info?.source
    const source = raw
      ? await settleWithin(locate(raw), sourceBudgetMs, { file: projectPath(raw.url, roots), line: null, column: null })
      : null
    return {
      id: idOf(element),
      role,
      label: labelOf(element, role),
      text: textOf(element),
      testId: testIdOf(element)?.value ?? null,
      selector: selectorOf(element),
      component: info?.component ?? null,
      ownerStack: info?.ownerStack ?? [],
      source,
      bounds: boundsOf(element),
      state: {
        disabled: element.matches(":disabled") || element.getAttribute("aria-disabled") === "true",
        focused: deepActiveElement(element.ownerDocument) === element,
      },
      props: propsMode === "safe" && info ? safeProps(info.props) : null,
    }
  }
}

export type Describe = ReturnType<typeof createDescriber>
