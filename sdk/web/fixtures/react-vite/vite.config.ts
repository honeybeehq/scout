import { defineConfig } from "vite"
import react from "@vitejs/plugin-react"
import { scout } from "@scout/vite"

export default defineConfig({
  build: { rolldownOptions: { input: ["index.html", "game.html"] } },
  plugins: [
    react(),
    scout({ app: { name: "Acme Checkout" } }),
    {
      name: "scout-game-fixture-name",
      apply: "serve",
      transformIndexHtml(html, context) {
        return context.path === "/game.html" ? html.replace("Acme Checkout", "Scout game fixture") : html
      },
    },
  ],
})
