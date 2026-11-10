import { spawn } from 'node:child_process';
import fs from 'node:fs';
const CH = process.env.LOGO_CHROME || process.env.HOME + '/.cache/ms-playwright/chromium_headless_shell-1248/chrome-headless-shell-linux64/chrome-headless-shell';
export async function launch() {
  if (!fs.existsSync(CH)) throw new Error('browser missing: ' + CH);
  const port = 9300 + Math.floor(Math.random() * 500);
  const profile = fs.mkdtempSync('/tmp/scout-signal-logo-chrome-');
  const p = spawn(CH, ['--headless=new', `--remote-debugging-port=${port}`, '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--allow-file-access-from-files', '--hide-scrollbars', `--user-data-dir=${profile}`, 'about:blank'], { stdio: 'ignore' });
  p.on('error', e => { console.error('spawn failed', e); process.exit(1); });
  let list;
  for (let i = 0; i < 150; i++) { try { list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json(); if (list.length) break; } catch {} await new Promise(r => setTimeout(r, 100)); }
  const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
  await new Promise(r => ws.onopen = r);
  let id = 0; const pend = new Map();
  ws.onmessage = m => { const d = JSON.parse(m.data); if (d.id && pend.has(d.id)) { pend.get(d.id)(d); pend.delete(d.id); } };
  const send = (method, params = {}) => new Promise((res, rej) => { const i = ++id; pend.set(i, d => d.error ? rej(new Error(method + ': ' + JSON.stringify(d.error))) : res(d.result)); ws.send(JSON.stringify({ id: i, method, params })); });
  await send('Page.enable'); await send('Runtime.enable');
  return {
    send,
    async goto(url, w = 1024, h = 1024) {
      await send('Emulation.setDeviceMetricsOverride', { width: w, height: h, deviceScaleFactor: 1, mobile: false });
      await send('Page.navigate', { url });
      for (let i = 0; i < 3000; i++) { const r = await send('Runtime.evaluate', { expression: 'window.__done===true', returnByValue: true }).catch(() => null); if (r?.result?.value) return; await new Promise(r => setTimeout(r, 100)); }
      throw new Error('timeout ' + url);
    },
    async eval(expr) { const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true }); if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails)); return r.result.value; },
    close() { ws.close(); p.kill('SIGKILL'); fs.rmSync(profile, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 }); }
  };
}
