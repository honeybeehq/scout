import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

export default {
  plugins: [{
    name: 'scout-local', apply: 'serve',
    transformIndexHtml() {
      try {
        const { port, token, sdkURL } = JSON.parse(readFileSync(process.env.SCOUT_BRIDGE_FILE ?? join(homedir(), 'Library/Application Support/Scout/bridge.json'), 'utf8'))
        const config = JSON.stringify({ port, token, projectRoot: process.env.SCOUT_PROJECT_ROOT ?? process.cwd() }).replace(/</g, '\\u003c')
        return [
          { tag: 'script', children: `window.__SCOUT__=${config}`, injectTo: 'head-prepend' },
          { tag: 'script', attrs: { type: 'module', src: sdkURL ?? `http://127.0.0.1:${port}/sdk/v1/scout.js` }, injectTo: 'head' },
        ]
      } catch { return [] }
    },
  }],
}
