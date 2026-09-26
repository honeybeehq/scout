import type { SafeProps } from "./types"

const MAX_PROPS = 20
const MAX_STRING = 64
const REDACTED_KEYS = /pass|secret|token|key|auth|card|ssn/i
const INPUT_VALUE_KEYS = /^(value|defaultValue)$/
const SKIPPED_KEYS = new Set(["children", "ref", "key", "dangerouslySetInnerHTML"])

export function safeProps(raw: unknown): SafeProps | null {
  if (!raw || typeof raw !== "object") return null
  const props: SafeProps = {}
  let count = 0
  for (const [key, value] of Object.entries(raw as Record<string, unknown>)) {
    if (count >= MAX_PROPS) break
    if (SKIPPED_KEYS.has(key)) continue
    if (REDACTED_KEYS.test(key) || INPUT_VALUE_KEYS.test(key)) {
      props[key] = "[redacted]"
    } else if (value === null || typeof value === "boolean") {
      props[key] = value
    } else if (typeof value === "number" && Number.isFinite(value)) {
      props[key] = value
    } else if (typeof value === "string") {
      props[key] = value.slice(0, MAX_STRING)
    } else {
      continue
    }
    count += 1
  }
  return count > 0 ? props : null
}
