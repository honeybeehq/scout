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
const params = new URLSearchParams(location.search)
const fixture = { geometry: {} as Record<string, unknown>, pointAt: null as string | null, pointSamples: 0, hitchAt: null as number | null, hitchEvery: null as number | null, hitchCount: 0, hitchFiredAt: null as number | null }
Object.assign(window, { __SCOUT_GAME_FIXTURE__: fixture })
const reportFixture = (log = true) => {
  document.querySelector("#fixture-info")!.textContent = JSON.stringify(fixture, null, 2)
  if (log) console.info("[scout-game-fixture]", JSON.stringify(fixture))
}
let screenOrigin: { x: number; y: number } | null = null
const measureCentre = (event?: PointerEvent, publish = true) => {
  const bounds = canvas.getBoundingClientRect()
  const x = bounds.left + canvas.clientLeft + 260 * canvas.clientWidth / canvas.width
  const y = bounds.top + canvas.clientTop + 180 * canvas.clientHeight / canvas.height
  if (event?.isTrusted) screenOrigin = { x: event.screenX - event.clientX, y: event.screenY - event.clientY }
  const estimatedScreenCentre = { x: window.screenX + (outerWidth - innerWidth) / 2 + x, y: window.screenY + outerHeight - innerHeight + y }
  const calibratedScreenCentre = screenOrigin ? { x: screenOrigin.x + x, y: screenOrigin.y + y } : null
  fixture.geometry = {
    viewportCentre: { x, y },
    window: { x: window.screenX, y: window.screenY, outerWidth, outerHeight, innerWidth, innerHeight, devicePixelRatio },
    estimatedScreenCentre,
    calibratedScreenCentre,
    coordinateRule: "macOS points at 100% zoom; only trusted pointer events calibrate screen origin",
  }
  if (publish) reportFixture()
  const screen = calibratedScreenCentre ?? estimatedScreenCentre
  return { x, y, screenX: screen.x, screenY: screen.y }
}
measureCentre()
addEventListener("resize", () => measureCentre())
addEventListener("scroll", () => measureCentre())
addEventListener("pointermove", (event) => {
  if (event.isTrusted) measureCentre(event)
})
const hitch = () => {
  fixture.hitchCount++
  fixture.hitchFiredAt = performance.now()
  const until = performance.now() + 90
  while (performance.now() < until) Math.sqrt(frame)
  reportFixture()
}
document.querySelector("#hitch")!.addEventListener("click", hitch)
const hitchParam = params.get("hitchAt")
if (hitchParam !== null && Number.isFinite(Number(hitchParam)) && Number(hitchParam) >= 0) {
  fixture.hitchAt = Number(hitchParam)
  reportFixture()
  setTimeout(hitch, Math.max(0, fixture.hitchAt - performance.now()))
}
const hitchEvery = Number(params.get("hitchEvery"))
if (Number.isFinite(hitchEvery) && hitchEvery > 0) {
  fixture.hitchEvery = Math.max(1000, hitchEvery)
  reportFixture()
  setInterval(hitch, fixture.hitchEvery)
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
  if (params.get("pointAt") === "asteroid") {
    fixture.pointAt = "asteroid"
    const pointAtAsteroid = () => {
      const point = measureCentre(undefined, false)
      canvas.dispatchEvent(new PointerEvent("pointermove", { bubbles: true, view: window, pointerType: "mouse", pointerId: 1, isPrimary: true, clientX: point.x, clientY: point.y, screenX: point.screenX, screenY: point.screenY }))
      fixture.pointSamples++
      reportFixture(false)
    }
    pointAtAsteroid()
    setInterval(pointAtAsteroid, 200)
  }
}
