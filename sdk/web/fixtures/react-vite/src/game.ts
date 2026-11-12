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
document.querySelector("#hitch")!.addEventListener("click", () => {
  const until = performance.now() + 90
  while (performance.now() < until) Math.sqrt(frame)
})
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
