import { isEditable, tagOf, testIdOf } from "./aria"

const INTERACTIVE_TAGS = /^(button|input|select|textarea|summary|option)$/
const INTERACTIVE_ROLES = new Set([
  "button", "checkbox", "combobox", "link", "listbox", "menuitem", "menuitemcheckbox", "menuitemradio",
  "option", "radio", "searchbox", "slider", "spinbutton", "switch", "tab", "textbox", "treeitem",
])
const MEANINGFUL_TAGS = /^(img|svg|video|audio|canvas|iframe|picture|h[1-6]|p|li|dt|dd|td|th|label|figure|pre|code|blockquote|form|fieldset|section|article|aside|nav|main|header|footer|dialog|table|ul|ol)$/
const PROMOTION_DEPTH = 8
const SVG = "http://www.w3.org/2000/svg"

export function parentOf(element: Element): Element | null {
  if (element.parentElement) return element.parentElement
  const parent = element.parentNode as ShadowRoot | null
  return parent && parent.nodeType === 11 && parent.host ? parent.host : null
}

function isRoot(element: Element): boolean {
  const tag = tagOf(element)
  return tag === "body" || tag === "html"
}

function isInteractive(element: Element, depth: number): boolean {
  const tag = tagOf(element)
  if (tag === "a" || tag === "area") return element.hasAttribute("href")
  if (INTERACTIVE_TAGS.test(tag)) return true
  const role = element.getAttribute("role")
  if (role && INTERACTIVE_ROLES.has(role)) return true
  if (isEditable(element)) {
    const parent = parentOf(element)
    return !parent || !isEditable(parent)
  }
  const tabIndex = element.getAttribute("tabindex")
  return depth <= 2 && tabIndex !== null && Number(tabIndex) >= 0
}

function hasOwnText(element: Element): boolean {
  for (const node of Array.from(element.childNodes)) {
    if (node.nodeType === 3 && node.nodeValue?.trim()) return true
  }
  return false
}

function isMeaningful(element: Element): boolean {
  return !!testIdOf(element)
    || element.hasAttribute("role")
    || element.hasAttribute("aria-label")
    || element.hasAttribute("aria-labelledby")
    || MEANINGFUL_TAGS.test(tagOf(element))
    || hasOwnText(element)
}

export function promote(leaf: Element): Element | null {
  const start = leaf.namespaceURI === SVG && tagOf(leaf) !== "svg" ? leaf.closest("svg") ?? leaf : leaf
  let node: Element | null = start
  for (let depth = 0; node && depth < PROMOTION_DEPTH && !isRoot(node); depth += 1, node = parentOf(node)) {
    if (isInteractive(node, depth)) return node
  }
  node = start
  for (let depth = 0; node && depth < PROMOTION_DEPTH && !isRoot(node); depth += 1, node = parentOf(node)) {
    if (isMeaningful(node)) return node
  }
  return isRoot(start) ? null : start
}

export function deepElementAt(x: number, y: number): Element | null {
  let element = document.elementFromPoint(x, y)
  for (let depth = 0; element && depth < 16; depth += 1) {
    const shadow = element.shadowRoot
    if (shadow) {
      const inner = shadow.elementFromPoint(x, y)
      if (inner && inner !== element) {
        element = inner
        continue
      }
    }
    const tag = tagOf(element)
    if (tag === "iframe" || tag === "frame") {
      let inner: Document | null = null
      try {
        inner = (element as HTMLIFrameElement).contentDocument
      } catch {
        inner = null
      }
      if (inner) {
        const rect = element.getBoundingClientRect()
        x -= rect.left + element.clientLeft
        y -= rect.top + element.clientTop
        const next = inner.elementFromPoint(x, y)
        if (next) {
          element = next
          continue
        }
      }
    }
    break
  }
  return element
}

export function frameOffset(view: Window | null): { x: number; y: number } {
  let x = 0
  let y = 0
  let current = view
  while (current && current !== window) {
    let frame: Element | null = null
    try {
      frame = current.frameElement
    } catch {
      frame = null
    }
    if (!frame) break
    const rect = frame.getBoundingClientRect()
    x += rect.left + frame.clientLeft
    y += rect.top + frame.clientTop
    current = frame.ownerDocument.defaultView
  }
  return { x, y }
}

export function sameOriginFrames(root: Document = document, found: Window[] = []): Window[] {
  for (const frame of Array.from(root.querySelectorAll("iframe, frame"))) {
    try {
      const inner = (frame as HTMLIFrameElement).contentDocument
      const view = inner?.defaultView
      if (inner && view) {
        found.push(view)
        sameOriginFrames(inner, found)
      }
    } catch {
      continue
    }
  }
  return found
}
