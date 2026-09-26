const IMPLICIT_ROLES: Record<string, string> = {
  article: "article",
  aside: "complementary",
  button: "button",
  dialog: "dialog",
  fieldset: "group",
  form: "form",
  h1: "heading",
  h2: "heading",
  h3: "heading",
  h4: "heading",
  h5: "heading",
  h6: "heading",
  hr: "separator",
  li: "listitem",
  main: "main",
  meter: "meter",
  nav: "navigation",
  ol: "list",
  option: "option",
  output: "status",
  progress: "progressbar",
  summary: "button",
  table: "table",
  td: "cell",
  textarea: "textbox",
  th: "columnheader",
  tr: "row",
  ul: "list",
}

const INPUT_ROLES: Record<string, string> = {
  button: "button",
  checkbox: "checkbox",
  image: "button",
  radio: "radio",
  range: "slider",
  reset: "button",
  search: "searchbox",
  submit: "button",
  number: "spinbutton",
}

const NAME_FROM_CONTENT = new Set([
  "button", "cell", "checkbox", "columnheader", "heading", "link", "listitem", "menuitem",
  "menuitemcheckbox", "menuitemradio", "option", "radio", "row", "rowheader", "switch", "tab",
  "tooltip", "treeitem",
])

const SKIPPED_SUBTREES = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "TEXTAREA", "SELECT", "INPUT"])
const TEST_ID_ATTRIBUTES = ["data-testid", "data-test-id", "data-test", "data-cy", "data-qa"]
const LABEL_LIMIT = 120
const TEXT_LIMIT = 80

export function tagOf(element: Element): string {
  return element.localName
}

export function isFormControl(element: Element): boolean {
  return /^(input|textarea|select)$/.test(tagOf(element))
}

export function isEditable(element: Element): boolean {
  return (element as HTMLElement).isContentEditable === true
}

export function roleOf(element: Element): string | null {
  const explicit = element.getAttribute("role")?.trim().split(/\s+/)[0]
  if (explicit) return explicit
  const tag = tagOf(element)
  if (tag === "a" || tag === "area") return element.hasAttribute("href") ? "link" : null
  if (tag === "img") return element.getAttribute("alt") === "" ? "presentation" : "img"
  if (tag === "select") {
    const select = element as HTMLSelectElement
    return select.multiple || select.size > 1 ? "listbox" : "combobox"
  }
  if (tag === "input") {
    const type = (element.getAttribute("type") ?? "text").toLowerCase()
    if (type === "hidden") return null
    return INPUT_ROLES[type] ?? (element.hasAttribute("list") ? "combobox" : "textbox")
  }
  if (tag === "section") return hasOwnName(element) ? "region" : null
  if (isEditable(element) && !isEditable(element.parentElement ?? element)) return "textbox"
  return IMPLICIT_ROLES[tag] ?? null
}

function hasOwnName(element: Element): boolean {
  return element.hasAttribute("aria-label") || element.hasAttribute("aria-labelledby")
}

export function clip(value: string | null | undefined, limit: number): string | null {
  const collapsed = value?.replace(/\s+/g, " ").trim()
  if (!collapsed) return null
  return collapsed.length > limit ? `${collapsed.slice(0, limit - 1)}…` : collapsed
}

export function collectText(root: Element, limit: number): string | null {
  const document = root.ownerDocument
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      if (node.nodeType === Node.TEXT_NODE) return NodeFilter.FILTER_ACCEPT
      const element = node as Element
      if (SKIPPED_SUBTREES.has(element.tagName.toUpperCase())) return NodeFilter.FILTER_REJECT
      if (element !== root && (isEditable(element) || element.getAttribute("aria-hidden") === "true")) {
        return NodeFilter.FILTER_REJECT
      }
      return NodeFilter.FILTER_SKIP
    },
  })
  let text = ""
  while (walker.nextNode() && text.length < limit * 3) text += ` ${walker.currentNode.nodeValue ?? ""}`
  return clip(text, limit)
}

function labelledBy(element: Element): string | null {
  const ids = element.getAttribute("aria-labelledby")
  if (!ids) return null
  const root = element.getRootNode() as Document | ShadowRoot
  const text = ids
    .split(/\s+/)
    .map((id) => {
      const target = root.getElementById?.(id) ?? element.ownerDocument.getElementById(id)
      return target ? collectText(target, LABEL_LIMIT) ?? "" : ""
    })
    .join(" ")
  return clip(text, LABEL_LIMIT)
}

function controlLabel(element: Element): string | null {
  const labels = (element as HTMLInputElement).labels
  if (labels && labels.length > 0) {
    return clip(Array.from(labels, (label) => collectText(label, LABEL_LIMIT) ?? "").join(" "), LABEL_LIMIT)
  }
  const wrapping = element.closest("label")
  return wrapping ? collectText(wrapping, LABEL_LIMIT) : null
}

export function labelOf(element: Element, role: string | null): string | null {
  const direct = clip(element.getAttribute("aria-label"), LABEL_LIMIT) ?? labelledBy(element)
  if (direct) return direct
  if (isFormControl(element)) {
    return controlLabel(element)
      ?? clip(element.getAttribute("title"), LABEL_LIMIT)
      ?? clip(element.getAttribute("placeholder"), LABEL_LIMIT)
  }
  const alt = clip(element.getAttribute("alt"), LABEL_LIMIT)
  if (alt) return alt
  if (role && NAME_FROM_CONTENT.has(role) && !isEditable(element)) {
    const text = collectText(element, LABEL_LIMIT)
    if (text) return text
  }
  if (tagOf(element) === "svg") return clip(element.querySelector("title")?.textContent, LABEL_LIMIT)
  return clip(element.getAttribute("title"), LABEL_LIMIT)
}

export function textOf(element: Element): string | null {
  if (isFormControl(element) || isEditable(element)) return null
  return collectText(element, TEXT_LIMIT)
}

export function testIdOf(element: Element): { attribute: string; value: string } | null {
  for (const attribute of TEST_ID_ATTRIBUTES) {
    const value = element.getAttribute(attribute)
    if (value) return { attribute, value }
  }
  return null
}
