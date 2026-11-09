import {launch} from './cdp.mjs'; import fs from 'node:fs';
const p=await launch(); await p.goto('file://'+fs.realpathSync('src/box.html'));
for (const a of process.argv.slice(2)) { const [src,N,out]=a.split(':');
  const u=await p.eval(`box(${JSON.stringify('file://'+fs.realpathSync(src))},${N})`);
  fs.writeFileSync(out, Buffer.from(u.split(',')[1],'base64')); console.log(out); }
p.close();
