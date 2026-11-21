import { execFileSync, spawn } from 'node:child_process'
import { mkdirSync, rmSync, readFileSync, writeFileSync, readdirSync } from 'node:fs'
import { dirname, resolve, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { WebSocket } from 'ws'

if (process.platform !== 'darwin') {
  console.log('SKIP native game-owner e2e: requires macOS Network.framework and Swift')
  process.exit(0)
}

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../..')
const proof = join(root, '.audit/g3/owner')
rmSync(proof, {recursive:true,force:true})
mkdirSync(proof, {recursive:true})
execFileSync('swift', ['build'], {cwd:root,stdio:'inherit'})
const objects = readdirSync(join(root,'.build/debug/ScoutCore.build')).filter(f=>f.endsWith('.swift.o')).map(f=>join(root,'.build/debug/ScoutCore.build',f))
const exe = join(proof,'game-owner-proof')
let harness = join(root,'sdk/web/scripts/game-owner-proof.swift')
let bridgeSource = join(root,'mac/Scout/Bridge/BridgeServer.swift')
let composerSource = join(root,'mac/Scout/Delivery/TaskComposer.swift')
if (process.env.SCOUT_OWNER_BASELINE) {
  for (const [relative, name] of [['mac/Scout/Bridge/BridgeServer.swift','BridgeServer'],['mac/Scout/Delivery/TaskComposer.swift','TaskComposer']]) {
    writeFileSync(join(proof,`${name}.swift`),execFileSync('git',['show',`${process.env.SCOUT_OWNER_BASELINE}:${relative}`],{cwd:root}))
  }
  bridgeSource = join(proof,'BridgeServer.swift')
  composerSource = join(proof,'TaskComposer.swift')
  const legacy = readFileSync(harness,'utf8').replace('bridge.project(for: snippet)!','(bridge.project(forLocation: snippet.primaryContext?.location) ?? snippet.targets.lazy.compactMap(bridge.project(forTarget:)).first)!').replace('projectRoot: \"/fixture/stale\", clientID:', 'projectRoot: \"/fixture/current\", clientID:')
  harness = join(proof,'GameOwnerProof.swift')
  writeFileSync(harness,legacy)
}
execFileSync('swiftc', ['-swift-version','6','-default-isolation','MainActor','-I',join(root,'.build/debug/Modules'),harness,bridgeSource,join(root,'mac/Scout/Bridge/SDKServer.swift'),join(root,'mac/Scout/Bridge/BridgeMessages.swift'),composerSource,...objects,'-o',exe],{cwd:root,stdio:'inherit'})
const child = spawn(exe,[proof],{env:{...process.env,SCOUT_DATA_ROOT:join(proof,'data')},stdio:['ignore','pipe','pipe']})
const clients = []
const records = []
let output = '', errors = ''
child.stderr.on('data', b => { errors += b })
const exit = new Promise(r=>child.once('exit',r))
try {
  const config = await new Promise((resolve,reject)=>{
    const timeout = setTimeout(()=>reject(Error(errors || output)),20000)
    child.stdout.on('data', b=>{
      output += b
      if (output.includes('\n')) {clearTimeout(timeout);resolve(JSON.parse(output.split('\n')[0]))}
    })
  })
  for (const [index,projectRoot] of ['/fixture/stale','/fixture/current'].entries()) {
    const ws = new WebSocket(`ws://127.0.0.1:${config.port}/v1`,{origin:'http://127.0.0.1:5178'})
    clients.push(ws)
    const element = {id:'game:Same game:asteroid-17',kind:'game',game:{entity:{id:'asteroid-17',kind:'asteroid',label:'Asteroid A-17'}},role:'asteroid',label:'Asteroid A-17',bounds:{x:0,y:0,width:800,height:400,space:'viewport'}}
    ws.on('message',data=>{
      const msg=JSON.parse(data); records.push({projectRoot,dir:'in',msg})
      const send=msg=>{records.push({projectRoot,dir:'out',msg});ws.send(JSON.stringify({v:1,...msg}))}
      if(msg.type==='welcome')send({type:'hover',at:Date.now(),element})
      if(msg.type==='pin')send({type:'pinned',id:msg.id,element})
      if(msg.type==='snapshot'){
        send({type:'gameState',id:msg.id,game:{name:'Same game',build:'owner-fixture',scene:projectRoot,frame:120,clock:2,position:{x:index},save:{owner:projectRoot},saveStatus:'included'}})
        send({type:'gameStateDone',id:msg.id})
      }
    })
    await new Promise((resolve,reject)=>{ws.once('open',()=>{ws.send(JSON.stringify({v:1,type:'hello',token:config.token,app:{name:'Same game',url:'http://127.0.0.1:5178'},project:{root:projectRoot},capabilities:['game']}));resolve()});ws.once('error',reject)})
    await new Promise(r=>setTimeout(r,150))
  }
  const status = await Promise.race([exit,new Promise((_,reject)=>setTimeout(()=>reject(Error('owner harness timeout')),15000))])
  if(status!==0)throw Error(errors || output)
  const result=JSON.parse(output.trim().split('\n').at(-1))
  if(result.projectRoot!=='/fixture/current'||result.locationProjectRoot!=='/fixture/current'||result.state.scene!=='/fixture/current'||result.save.owner!=='/fixture/current')throw Error(JSON.stringify(result))
  if(records.some(r=>r.projectRoot==='/fixture/stale'&&r.msg.type==='snapshot'))throw Error('stale client received snapshot')
  writeFileSync(join(proof,'result.json'),JSON.stringify(result,null,2))
  console.log('PASS two same-origin game clients: new pin owns project, snapshot, task state and save')
  console.log(readFileSync(join(proof,'message.txt'),'utf8'))
} finally {
  for(const ws of clients)ws.close()
  child.kill()
  writeFileSync(join(proof,'protocol.json'),JSON.stringify(records,null,2))
  writeFileSync(join(proof,'harness.log'),(output+'\n'+errors).replace(/\"token\"\s*:\s*\"[^\"]*\"/g, '\"token\":\"<REDACTED>\"'))
}
