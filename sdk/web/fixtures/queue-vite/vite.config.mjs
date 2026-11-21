import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

function loadScout(url) {
  const timing = window.__SCOUT_LOADER_TIMING__ = { loaderAttemptAt: [], sdkLoadedAt: null, wsConnectedAt: null }
  let done = false, busy = false, timer, attempt = 0, fastUntil = 30000
  const wake = () => {
    if (done || busy) return
    clearTimeout(timer)
    busy = true
    timing.loaderAttemptAt.push(performance.now())
    import(`${url}#scout-retry-${attempt++}`).then(sdk => {
      done = true
      timing.sdkLoadedAt = performance.now()
      const handle = sdk.startScout()
      const connected = setInterval(() => {
        if (handle.connected) { timing.wsConnectedAt = performance.now(); clearInterval(connected) }
      }, 25)
      removeEventListener('focus', focus)
      document.removeEventListener('visibilitychange', visible)
    }).catch(() => {
      const cap = performance.now() < fastUntil ? 750 : 2000
      timer = setTimeout(wake, Math.min(250 * 2 ** (attempt - 1), cap) * (0.9 + Math.random() * 0.2))
    })
      .finally(() => { busy = false })
  }
  const focus = () => { fastUntil = performance.now() + 30000; wake() }
  const visible = () => { if (document.visibilityState === 'visible') focus() }
  addEventListener('focus', focus)
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
