import { boundsOf } from "./describe"

export type Tone = "beam" | "flare"

export interface Overlay {
  aim(element: Element | null, chip?: string): void
  flash(element: Element, tone: Tone, durationMs: number, chip?: string): void
  destroy(): void
}

interface Flash {
  element: Element
  box: HTMLElement
  until: number
}

const STYLE = `
.box{position:fixed;box-sizing:border-box;border:2px solid var(--tone);border-radius:4px;
background:color-mix(in srgb,var(--tone) 10%,transparent);
box-shadow:0 0 0 1px rgb(7 8 13/.35),0 0 14px color-mix(in srgb,var(--tone) 45%,transparent);
animation:in 120ms ease-out}
.beam{--tone:#8B96FF}.flare{--tone:#FF6A3D}
.chip{position:absolute;left:-2px;bottom:calc(100% + 4px);max-width:420px;overflow:hidden;
white-space:nowrap;text-overflow:ellipsis;padding:2px 7px;border-radius:5px;background:var(--tone);
color:#07080D;font:600 11px/16px -apple-system,BlinkMacSystemFont,system-ui,sans-serif}
.chip:empty{display:none}.below .chip{bottom:auto;top:calc(100% + 4px)}
.out{opacity:0;transition:opacity 200ms}
@keyframes in{from{opacity:0}}
@media (prefers-reduced-motion:reduce){.box{animation:none}.out{transition:none}}`

function createBox(tone: Tone, kind: string): HTMLElement {
  const box = document.createElement("div")
  box.className = `box ${tone}`
  box.dataset.box = kind
  const chip = document.createElement("div")
  chip.className = "chip"
  box.append(chip)
  return box
}

function place(box: HTMLElement, element: Element) {
  const bounds = element.isConnected ? boundsOf(element) : null
  const visible = !!bounds && (bounds.width > 0 || bounds.height > 0)
  box.style.display = visible ? "" : "none"
  if (!bounds || !visible) return
  box.style.left = `${bounds.x}px`
  box.style.top = `${bounds.y}px`
  box.style.width = `${bounds.width}px`
  box.style.height = `${bounds.height}px`
  box.classList.toggle("below", bounds.y < 24)
}

export function createOverlay(): Overlay {
  const host = document.createElement("scout-overlay")
  host.style.cssText = "all:initial;position:fixed;inset:0;pointer-events:none;z-index:2147483647;contain:layout style"
  const root = host.attachShadow({ mode: "open" })
  const style = document.createElement("style")
  style.textContent = STYLE
  root.append(style)
  const aimBox = createBox("beam", "aim")
  const flashes = new Set<Flash>()
  let target: Element | null = null
  let frame = 0

  const tick = () => {
    frame = 0
    if (target) place(aimBox, target)
    const now = performance.now()
    flashes.forEach((flash) => {
      if (now >= flash.until + 200) {
        flash.box.remove()
        flashes.delete(flash)
      } else {
        place(flash.box, flash.element)
        flash.box.classList.toggle("out", now >= flash.until)
      }
    })
    if (target || flashes.size > 0) frame = requestAnimationFrame(tick)
    else host.remove()
  }

  const mount = () => {
    if (!host.isConnected) document.documentElement.append(host)
    if (!frame) frame = requestAnimationFrame(tick)
  }

  return {
    aim(element, chip = "") {
      target = element
      if (!element) {
        aimBox.remove()
        return
      }
      aimBox.firstElementChild!.textContent = chip
      if (!aimBox.isConnected) root.append(aimBox)
      place(aimBox, element)
      mount()
    },
    flash(element, tone, durationMs, chip = "") {
      const box = createBox(tone, "flash")
      box.firstElementChild!.textContent = chip
      root.append(box)
      place(box, element)
      flashes.add({ element, box, until: performance.now() + durationMs })
      mount()
    },
    destroy() {
      if (frame) cancelAnimationFrame(frame)
      frame = 0
      target = null
      flashes.clear()
      host.remove()
    },
  }
}
