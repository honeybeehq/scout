import { spawn } from 'node:child_process'
import { createServer } from 'node:http'
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { chromium } from 'playwright'
import { startMockBridge } from './mock-bridge.mjs'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const fixture = join(root, 'fixtures/queue-vite')
const evidence = join(root, '../../.audit/g3')
mkdirSync(evidence, { recursive: true })
const scratch = mkdtempSync(join(tmpdir(), 'scout-queue-'))
const http = createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*')
  res.setHeader('Cross-Origin-Resource-Policy', 'cross-origin')
  res.setHeader('Content-Type', 'text/javascript')
  if (req.url !== '/sdk/v1/scout.js') { res.writeHead(404).end(); return }
  res.end(readFileSync(join(root, 'packages/web/dist/index.js')))
})
await new Promise(r => http.listen(0, '127.0.0.1', r))
const bridge = await startMockBridge({ port: 47818, token: 'queue-e2e-token' })
const sdkURL = process.env.SCOUT_SDK_URL ?? `http://127.0.0.1:${http.address().port}/sdk/v1/scout.js`
const bridgeFile = join(scratch, 'bridge.json')
writeFileSync(bridgeFile, JSON.stringify({port:47818,token:'queue-e2e-token',sdkURL}))
const vite = spawn(join(root, 'fixtures/react-vite/node_modules/.bin/vite'), [fixture, '--host', '127.0.0.1', '--port', '5178', '--strictPort'], {env:{...process.env,SCOUT_BRIDGE_FILE:bridgeFile},stdio:['ignore','pipe','pipe']})
let output = ''
const ready = new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error(output)), 20000)
  const onData = b => { output += b; if (output.includes('127.0.0.1:5178')) { clearTimeout(timer); resolve() } }
  vite.stdout.on('data', onData); vite.stderr.on('data', onData)
})
const browser = await chromium.launch({headless:true})
const page = await browser.newPage({viewport:{width:1200,height:850}})
const results = []
const assert = (ok, msg) => { if (!ok) throw new Error(msg) }
const incoming = (type, id) => e => e.dir === 'in' && e.msg.type === type && (id === undefined || e.msg.id === id)
async function step(name, fn) {
  try { await fn(); results.push({name,pass:true}); console.log(`PASS ${name}`) }
  catch (e) { results.push({name,pass:false,error:e.message}); console.log(`FAIL ${name}: ${e.message}`) }
}
async function snapshot(id) {
  const from = bridge.records.length
  bridge.broadcast({type:'snapshot',id})
  await bridge.waitFor(incoming('gameStateDone',id),{from})
  return bridge.records.slice(from).find(incoming('gameState',id))?.msg.game
}
async function aim() {
  await page.mouse.move(300,320)
  await page.waitForTimeout(300)
}
try {
  await ready
  bridge.setSession(true)
  await page.goto('http://127.0.0.1:5178')
  await page.waitForFunction(() => typeof window.preGame.unregister === 'function')
  await step('pre-SDK queue push names pinned entity and captures save', async () => {
    await aim()
    const pin = await bridge.pin()
    assert(pin.reply?.element?.label === 'Asteroid A-17',JSON.stringify(pin))
    const state = await bridge.waitFor(incoming('gameState',pin.id))
    assert(state.msg.game.save.seed === 42,JSON.stringify(state))
  })
  await step('highlight original entity ID and clear on duration', async () => {
    bridge.broadcast({type:'highlight',elementId:'game:Queue fixture:asteroid-17',durationMs:400})
    await page.waitForFunction(() => highlights.some(ids => ids[0] === 'asteroid-17'))
    await page.screenshot({path:join(evidence,'queue-highlight.png')})
    await page.waitForFunction(() => highlights.at(-1)?.length === 0)
  })
  await step('unregister clears highlight and snapshot', async () => {
    bridge.broadcast({type:'highlight',elementId:'game:Queue fixture:asteroid-17',durationMs:10000})
    await page.waitForFunction(() => highlights.at(-1)?.length === 1)
    await page.evaluate(() => preGame.unregister())
    assert(await page.evaluate(() => highlights.at(-1).length === 0),'highlight not cleared')
    assert(!await snapshot('removed'),'unregistered game replied')
    await page.evaluate(() => preGame.unregister())
  })
  await step('post-SDK push preserves array and return length', async () => {
    const ok = await page.evaluate(() => {
      window.postGame = makeGame('Post game')
      const before = __scoutGames.length
      return __scoutGames.push(postGame) === before + 1 && Array.isArray(__scoutGames) && typeof postGame.unregister === 'function'
    })
    assert(ok,'queue semantics changed')
    assert((await snapshot('post')).name === 'Post game','post queue did not register')
  })
  await step('unknown versions and malformed entries ignored', async () => {
    await page.evaluate(() => __scoutGames.push(null,{}, {...makeGame(),v:2}, {...makeGame(),canvas:document.body}, {...makeGame(),highlight:42}))
    assert((await snapshot('malformed')).name === 'Post game','bad entry replaced game')
  })
  await step('throwing describe snapshot and highlight stay isolated', async () => {
    await page.evaluate(() => {
      postGame.unregister()
      window.badGame = {...makeGame('Throwing'),describe(){throw Error('describe')},snapshot(){throw Error('snapshot')},highlight(){throw Error('highlight')}}
      __scoutGames.push(badGame)
    })
    await aim()
    assert(!await snapshot('throwing'),'throwing snapshot replied')
    await page.evaluate(() => { badGame.describe = makeGame().describe })
    await aim()
    const from = bridge.records.length
    bridge.broadcast({type:'pin',id:'bad-highlight',at:Date.now()})
    await bridge.waitFor(e => incoming('pinned','bad-highlight')(e) && e.msg.element?.kind === 'game',{from})
    bridge.broadcast({type:'highlight',elementId:'game:Throwing:asteroid-17',durationMs:100})
    await page.waitForTimeout(200)
    await page.evaluate(() => { badGame.unregister(); __scoutGames.push(window.postGame = makeGame('Recovered')) })
    assert((await snapshot('recovered')).name === 'Recovered','SDK failed to recover')
  })
  await step('adapter saveStatus and extra survive absent save', async () => {
    await page.evaluate(() => { postGame.snapshot = () => ({scene:'ring',frame:1,clock:0,position:null,saveStatus:'omitted: scenario 412 KiB, player save 301 KiB exceed 256 KiB',extra:{saveKind:'scenario',saveStatus:'too large'}}) })
    const game = await snapshot('adapter-omission')
    assert(game.saveStatus.startsWith('omitted: scenario 412') && game.extra.saveKind === 'scenario',JSON.stringify(game))
    await page.evaluate(() => { postGame.snapshot = () => ({...makeGame().snapshot(),saveStatus:'adapter override'}) })
    assert((await snapshot('sdk-status')).saveStatus === 'included','adapter overrode included')
  })
  await step('session end clears highlight and suppresses snapshots', async () => {
    await aim()
    const pin = await bridge.pin()
    assert(pin.reply?.element?.kind === 'game','missing game pin')
    bridge.broadcast({type:'highlight',elementId:'game:Recovered:asteroid-17',durationMs:10000})
    await page.waitForFunction(() => highlights.at(-1)?.length === 1)
    bridge.setSession(false)
    await page.waitForFunction(() => highlights.at(-1)?.length === 0)
    const from = bridge.records.length
    bridge.broadcast({type:'snapshot',id:'idle'})
    await page.waitForTimeout(200)
    assert(!bridge.records.slice(from).some(incoming('gameState')),'idle snapshot leaked')
  })
} finally {
  writeFileSync(join(evidence,'queue-bridge.json'),JSON.stringify(bridge.records,null,2))
  writeFileSync(join(evidence,'queue-results.json'),JSON.stringify({sdkURL,results},null,2))
  await browser.close(); vite.kill(); await bridge.close(); await new Promise(r => http.close(r))
}
console.log(`${results.filter(r=>r.pass).length}/${results.length} queue checks passed`)
if (results.some(r=>!r.pass)) process.exitCode = 1
