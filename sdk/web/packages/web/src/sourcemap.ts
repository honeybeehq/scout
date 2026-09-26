import { stripQuery } from "./paths"

interface IndexedMap {
  sources: string[]
  lines: number[][]
}

export interface OriginalPosition {
  url: string
  line: number
  column: number
}

const nativeFetch: typeof fetch | undefined = typeof fetch === "function" ? fetch.bind(globalThis) : undefined
const MAX_MAPS = 64
const MAX_BYTES = 8_000_000
const maps = new Map<string, Promise<IndexedMap | null>>()
const BASE64 = new Int8Array(128).fill(-1)
"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".split("").forEach((char, index) => {
  BASE64[char.charCodeAt(0)] = index
})

function decodeMappings(mappings: string): number[][] {
  const lines: number[][] = []
  let line: number[] = []
  let column = 0
  let source = 0
  let originalLine = 0
  let originalColumn = 0
  const values: number[] = []
  let index = 0
  const commit = () => {
    if (values.length >= 4) {
      column += values[0]!
      source += values[1]!
      originalLine += values[2]!
      originalColumn += values[3]!
      line.push(column, source, originalLine, originalColumn)
    } else if (values.length > 0) {
      column += values[0]!
    }
    values.length = 0
  }
  while (index < mappings.length) {
    const char = mappings.charCodeAt(index)
    if (char === 44) {
      commit()
      index += 1
    } else if (char === 59) {
      commit()
      lines.push(line)
      line = []
      column = 0
      index += 1
    } else {
      let value = 0
      let shift = 0
      let digit = 0
      do {
        digit = BASE64[mappings.charCodeAt(index++)] ?? -1
        if (digit < 0) return lines
        value += (digit & 31) << shift
        shift += 5
      } while (digit & 32)
      values.push(value & 1 ? -(value >>> 1) : value >>> 1)
    }
  }
  commit()
  lines.push(line)
  return lines
}

function decodeDataUrl(url: string): unknown {
  const comma = url.indexOf(",")
  const header = url.slice(0, comma)
  const body = url.slice(comma + 1)
  if (!header.endsWith(";base64")) return JSON.parse(decodeURIComponent(body))
  const binary = atob(body)
  const bytes = new Uint8Array(binary.length)
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index)
  return JSON.parse(new TextDecoder().decode(bytes))
}

async function loadMap(moduleUrl: string): Promise<IndexedMap | null> {
  if (!nativeFetch) return null
  const url = new URL(moduleUrl, location.href)
  if (url.origin !== location.origin) return null
  const response = await nativeFetch(url.href, { credentials: "same-origin" })
  if (!response.ok || Number(response.headers.get("content-length") ?? 0) > MAX_BYTES) return null
  const code = await response.text()
  const marker = code.lastIndexOf("sourceMappingURL=")
  if (marker < 0) return null
  const reference = code.slice(marker + 17).split(/\s/, 1)[0] ?? ""
  let base = url
  let raw: unknown
  if (reference.startsWith("data:")) {
    raw = decodeDataUrl(reference)
  } else {
    base = new URL(reference, url)
    if (base.origin !== location.origin) return null
    const mapResponse = await nativeFetch(base.href, { credentials: "same-origin" })
    if (!mapResponse.ok) return null
    raw = await mapResponse.json()
  }
  const map = raw as { mappings?: unknown; sources?: unknown; sourceRoot?: unknown }
  if (typeof map.mappings !== "string" || !Array.isArray(map.sources)) return null
  const root = typeof map.sourceRoot === "string" && map.sourceRoot ? map.sourceRoot.replace(/\/?$/, "/") : ""
  return {
    sources: map.sources.map((source) => new URL(root + String(source ?? ""), base).href),
    lines: decodeMappings(map.mappings),
  }
}

function mapFor(moduleUrl: string): Promise<IndexedMap | null> {
  let pending = maps.get(moduleUrl)
  if (!pending) {
    if (maps.size >= MAX_MAPS) maps.delete(maps.keys().next().value!)
    pending = loadMap(moduleUrl).catch(() => null)
    maps.set(moduleUrl, pending)
  }
  return pending
}

export async function originalPosition(url: string, line: number, column: number): Promise<OriginalPosition | null> {
  if (!/^https?:/.test(url)) return null
  const map = await mapFor(url)
  const segments = map?.lines[line - 1]
  if (!map || !segments || segments.length === 0) return null
  let best = 0
  for (let index = 0; index < segments.length; index += 4) {
    if (segments[index]! <= column - 1) best = index
    else break
  }
  const source = map.sources[segments[best + 1]!]
  if (!source) return null
  return { url: stripQuery(source), line: segments[best + 2]! + 1, column: segments[best + 3]! + 1 }
}
