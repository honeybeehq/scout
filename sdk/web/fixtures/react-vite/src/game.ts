const canvas = document.querySelector<HTMLCanvasElement>("#world")!
const context = canvas.getContext("2d")!
context.fillStyle = "#f2af50"
context.beginPath()
context.arc(260, 180, 48, 0, Math.PI * 2)
context.fill()
context.fillStyle = "white"
context.font = "20px system-ui"
context.fillText("Asteroid A-17", 195, 260)
let frame = 0
const tick = () => { frame++; requestAnimationFrame(tick) }
requestAnimationFrame(tick)
const fixture = { geometry: {} as Record<string, unknown>, hitchAt: null as number | null, hitchFiredAt: null as number | null }
Object.assign(window, { __SCOUT_GAME_FIXTURE__: fixture })
const reportFixture = () => {
  document.querySelector("#fixture-info")!.textContent = JSON.stringify(fixture, null, 2)
  console.info("[scout-game-fixture]", JSON.stringify(fixture))
}
const measureCentre = (event?: PointerEvent) => {
  const bounds = canvas.getBoundingClientRect()
  const x = bounds.left + canvas.clientLeft + 260 * canvas.clientWidth / canvas.width
  const y = bounds.top + canvas.clientTop + 180 * canvas.clientHeight / canvas.height
  fixture.geometry = {
    viewportCentre: { x, y },
    window: { x: window.screenX, y: window.screenY, outerWidth, outerHeight, innerWidth, innerHeight, devicePixelRatio },
    estimatedScreenCentre: { x: window.screenX + (outerWidth - innerWidth) / 2 + x, y: window.screenY + outerHeight - innerHeight + y },
    ...(event ? { calibratedScreenCentre: { x: event.screenX - event.clientX + x, y: event.screenY - event.clientY + y } } : {}),
    coordinateRule: "macOS screen points at 100% zoom; pointer-event calibration is authoritative",
  }
  reportFixture()
}
measureCentre()
addEventListener("resize", () => measureCentre())
addEventListener("scroll", () => measureCentre())
let calibrated = false
addEventListener("pointermove", (event) => {
  if (calibrated) return
  calibrated = true
  measureCentre(event)
})
const hitch = () => {
  fixture.hitchFiredAt = performance.now()
  const until = performance.now() + 90
  while (performance.now() < until) Math.sqrt(frame)
  reportFixture()
}
document.querySelector("#hitch")!.addEventListener("click", hitch)
const hitchParam = new URLSearchParams(location.search).get("hitchAt")
if (hitchParam !== null && Number.isFinite(Number(hitchParam)) && Number(hitchParam) >= 0) {
  fixture.hitchAt = Number(hitchParam)
  reportFixture()
  setTimeout(hitch, Math.max(0, fixture.hitchAt - performance.now()))
}
if (import.meta.env.DEV) {
  const { scout } = await import("../../../packages/web/src/index")
  scout.game({
    canvas,
    name: "Scout fixture",
    build: "fixture-1",
    describe: ({ x, y }) => Math.hypot(x - 260, y - 180) <= 48
      ? { entity: { id: "asteroid-17", kind: "asteroid", label: "Asteroid A-17" }, scene: "ring", layer: "rocks" }
      : null,
    snapshot: () => ({ scene: "ring", seed: 42, frame, clock: frame / 60, position: { x: 12, y: 4 }, save: document.querySelector<HTMLInputElement>("#large-save")!.checked ? { data: "x".repeat(262144) } : { version: 1, seed: 42, ship: { x: 12, y: 4 } }, extra: { storyStep: "first-rock" } }),
  })
  document.querySelector("#status")!.textContent = "Game hook registered · dev only"
}
