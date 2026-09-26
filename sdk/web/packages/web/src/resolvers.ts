import type { FrameworkResolver } from "./types"

const REGISTRY = Symbol.for("scout.resolvers")

type RegistryHost = { [REGISTRY]?: FrameworkResolver[] }

export function registeredResolvers(): FrameworkResolver[] {
  const host = globalThis as RegistryHost
  return (host[REGISTRY] ??= [])
}

export function registerResolver(resolver: FrameworkResolver): void {
  const list = registeredResolvers()
  const existing = list.findIndex((entry) => entry.name === resolver.name)
  if (existing >= 0) list[existing] = resolver
  else list.push(resolver)
}
