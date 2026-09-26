import { tagOf, testIdOf } from "./aria"

const MAX_SEGMENTS = 5

function escape(value: string): string {
  return typeof CSS !== "undefined" && CSS.escape ? CSS.escape(value) : value.replace(/[^\w-]/g, "\\$&")
}

function quote(value: string): string {
  return `"${value.replace(/["\\]/g, "\\$&")}"`
}

function stableId(element: Element): string | null {
  const id = element.id
  if (!id || /[:«»]|\d{4,}/.test(id)) return null
  const root = element.getRootNode() as Document | ShadowRoot
  try {
    return root.querySelectorAll(`#${escape(id)}`).length === 1 ? `#${escape(id)}` : null
  } catch {
    return null
  }
}

function anchor(element: Element): string | null {
  const testId = testIdOf(element)
  if (testId) return `[${testId.attribute}=${quote(testId.value)}]`
  return stableId(element)
}

function segment(element: Element): string {
  const tag = tagOf(element)
  const parent = element.parentElement
  if (!parent) return tag
  let index = 0
  let count = 0
  for (const sibling of Array.from(parent.children)) {
    if (sibling.localName !== element.localName) continue
    count += 1
    if (sibling === element) index = count
  }
  return count > 1 ? `${tag}:nth-of-type(${index})` : tag
}

export function selectorOf(element: Element): string {
  const segments: string[] = []
  let node: Element | null = element
  while (node && segments.length < MAX_SEGMENTS) {
    const anchored = anchor(node)
    if (anchored) {
      segments.unshift(anchored)
      break
    }
    if (node.localName === "body" || node.localName === "html") {
      if (segments.length === 0) segments.unshift(node.localName)
      break
    }
    segments.unshift(segment(node))
    node = node.parentElement
  }
  return segments.join(" > ")
}
