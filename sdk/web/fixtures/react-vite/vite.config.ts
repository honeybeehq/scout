import { defineConfig } from "vite"
import react from "@vitejs/plugin-react"
import { scout } from "@scout/vite"

export default defineConfig({
  build: { rolldownOptions: { input: ["index.html", "game.html"] } },
  plugins: [react(), scout({ app: { name: "Acme Checkout" } })],
})
