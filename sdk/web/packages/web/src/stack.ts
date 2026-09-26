import { isLibraryPath, parseFrame, projectPath } from "./paths"
import { originalPosition } from "./sourcemap"
import { settleWithin } from "./timing"
import type { PathRoots } from "./types"

const MAX_FRAMES = 12
const MAX_STACK = 4000

async function cleanLine(line: string, roots: PathRoots): Promise<string> {
  const frame = parseFrame(line)
  if (!frame) return line
  let { url, line: row, column } = frame
  if (!isLibraryPath(url)) {
    const original = await settleWithin(originalPosition(url, row, column), 500, null)
    if (original) ({ url, line: row, column } = original)
  }
  return `${line.slice(0, frame.start)}${projectPath(url, roots)}:${row}:${column}${line.slice(frame.end)}`
}

export async function cleanStack(stack: string | undefined, roots: PathRoots): Promise<string | undefined> {
  if (!stack) return undefined
  const all = stack.split("\n")
  const firstFrame = all.findIndex((line) => /^\s+at /.test(line))
  let seenAppFrame = false
  const lines = all.slice(Math.max(firstFrame, 0)).filter((line) => {
    const frame = parseFrame(line)
    if (!frame || !isLibraryPath(frame.url)) {
      seenAppFrame ||= !!frame
      return true
    }
    return !seenAppFrame
  }).slice(0, MAX_FRAMES)
  const cleaned = await Promise.all(lines.map((line) => cleanLine(line, roots)))
  return cleaned.join("\n").slice(0, MAX_STACK)
}
