import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

function loadScout(url) {
  let done = false, busy = false, timer, attempt = 0
  const wake = () => {
    if (done || busy) return
    clearTimeout(timer)
    busy = true
    import(`${url}#scout-retry-${attempt++}`).then(() => {
      done = true
      removeEventListener('focus', wake)
      document.removeEventListener('visibilitychange', visible)
    }).catch(() => { timer = setTimeout(wake, Math.min(1000 * 2 ** (attempt - 1), 2000)) })
      .finally(() => { busy = false })
  }
  const visible = () => { if (document.visibilityState === 'visible') wake() }
  addEventListener('focus', wake)
  document.addEventListener('visibilitychange', visible)
  wake()
}

export default {
  plugins: [{
    name: 'scout-local', apply: 'serve',
    transformIndexHtml() {
      try {
        const { port, token, sdkURL } = JSON.parse(readFileSync(process.env.SCOUT_BRIDGE_FILE ?? join(homedir(), 'Library/Application Support/Scout/bridge.json'), 'utf8'))
        const config = JSON.stringify({ port, token, projectRoot: process.env.SCOUT_PROJECT_ROOT ?? process.cwd() }).replace(/</g, '\\u003c')
        return [
          { tag: 'script', children: `window.__SCOUT__=${config}`, injectTo: 'head-prepend' },
          { tag: 'script', children: `(${loadScout})(${JSON.stringify(sdkURL ?? `http://127.0.0.1:${port}/sdk/v1/scout.js`).replace(/</g, '\\u003c')})`, injectTo: 'head' },
        ]
      } catch { return [] }
    },
  }],
}
