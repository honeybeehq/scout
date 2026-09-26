import { useSyncExternalStore } from "react"

const listeners = new Set<() => void>()

function subscribe(listener: () => void) {
  listeners.add(listener)
  addEventListener("popstate", listener)
  return () => {
    listeners.delete(listener)
    removeEventListener("popstate", listener)
  }
}

export function navigate(to: string) {
  history.pushState(null, "", to)
  listeners.forEach((listener) => listener())
}

export function usePath() {
  return useSyncExternalStore(subscribe, () => location.pathname)
}
