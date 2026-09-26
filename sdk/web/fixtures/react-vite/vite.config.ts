import { defineConfig } from "vite"
import react from "@vitejs/plugin-react"
import { scout } from "@scout/vite"

export default defineConfig({
  plugins: [react(), scout({ app: { name: "Acme Checkout" } })],
})
