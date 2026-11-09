import {launch} from './cdp.mjs'; import fs from 'node:fs';
const jobs = JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const p = await launch();
for (const j of jobs) {
  const d = {GW:412.0,GT:47.0,GCY:0.0,GR:185.4,GK:388.5/392,GSY:10.0,GSB:28.0,GSA:0.45,SMALL:0,MUD:1, ...j.d};
  for (const k in d) if (!['SMALL','MUD'].includes(k)) d[k]=Number.isInteger(d[k])?d[k]+'.0':String(d[k]);
  const t0=Date.now();
  await p.goto(`file://${fs.realpathSync('src/'+(process.env.LOGO_HTML||'icon2.html'))}?c=${j.c}&v=${j.v}&s=${j.s||1024}&d=${encodeURIComponent(JSON.stringify(d))}`);
  const err = await p.eval('window.__err||""'); if (err) { console.log(j.out, err); continue; }
  fs.writeFileSync(j.out, Buffer.from((await p.eval('window.__png')).split(',')[1], 'base64'));
  console.log(j.out, Date.now()-t0, 'ms');
}
p.close();
