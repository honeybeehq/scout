type Listener = () => void

const listeners = new Set<Listener>()
let patched = false

function patchHistory() {
  if (patched) return
  patched = true
  for (const method of ["pushState", "replaceState"] as const) {
    const original = history[method]
    history[method] = function (this: History, ...args: Parameters<History["pushState"]>) {
      const result = original.apply(this, args)
      listeners.forEach((listener) => listener())
      return result
    }
  }
}

export function currentRoute(custom?: () => string | null | undefined): string {
  try {
    const route = custom?.()
    if (route) return route
  } catch {
    return location.pathname
  }
  return location.hash.startsWith("#/") ? location.hash.slice(1).replace(/\?.*$/, "") : location.pathname
}

export function watchRoute(onChange: Listener): () => void {
  patchHistory()
  listeners.add(onChange)
  addEventListener("popstate", onChange)
  addEventListener("hashchange", onChange)
  const titles = new MutationObserver(onChange)
  titles.observe(document.head ?? document.documentElement, { childList: true, subtree: true, characterData: true })
  return () => {
    listeners.delete(onChange)
    removeEventListener("popstate", onChange)
    removeEventListener("hashchange", onChange)
    titles.disconnect()
  }
}
