import json, subprocess, os, shutil, sys
from gen import BASE, H16, H32, MID
MAIN = json.loads(next(l for l in open(os.path.join(os.path.dirname(os.path.abspath(__file__)),'final.py')) if l.startswith('MAIN = {')).split('=',1)[1])
SCOPE = {"TK":1.0,"TA":0.0,"TCX":0.0,"TCY":0.0,"LDEP":0.03,"LEX":0.05,"LR":0.165,"OW":0.010,"OIN":0.012,"OG":0.55,"OSG":0.12,"OBASE":0.62,
         "FILL":0.10,"FGRAD":0.0,"FGAIN":0.0,"FBASE":0.20,"OSTEP":0.0,"LBASE":0.55,"LSPAN":0.35,"LG":0.9,"LCORE":0.35,"LGX":-0.2,"LGY":0.25,"LRIM":0.4,
         "PHALO":0.9,"PBL":0.10,
         "LSOFT":1.0,"TRY":1.0,"RLIT":0.0,"SGAP":0.0,"SGW":1.0,"COX":0.0,"COY":0.0,"ORAMP":0.0,"GAPD":0.0,"SRY":1.0,"SOX":0.0,"SOY":0.0,"SRING":0.0,"SHOLE":0.0,"SLG":1.2}
CONCEPTS = {
 "angled":     {"TV":1,"TA":0.7854,"TK":1.08,"OW":0.028,"OIN":0.025,"OG":0.5,"OSG":0.3,"FILL":0.30,"FGRAD":0.2,"FGAIN":1.0,"LG":1.1,"LCORE":0.5},
 "horizontal": {"TV":2,"TA":0.0,"TK":1.25,"TCY":0.02,"OW":0.022,"OIN":0.02,"OG":0.55,"OSG":0.28,"FILL":0.26,"FGRAD":0.2,"FGAIN":1.0},
 "endon":      {"TV":3,"TK":1.0,"LR":0.27,"LEX":1.0,"OW":0.022,"OIN":0.02,"OG":0.5,"OSG":0.3,"FILL":0.25,"FGRAD":0.15,"FGAIN":0.5,"OSTEP":0.2},
}
S16D = {"SLO":0.40,"SSPAN":0.40,"SGAIN":1.6,"SHALO":0.3,"SHW":0.6}
S32D = {"SLO":0.40,"SSPAN":0.40,"SGAIN":1.5,"SHALO":0.5,"SHW":1.0}
def build(name, ovr=None, s16=None, s32=None, out='masters', full=True):
    ovr = ovr or {}
    base = {**BASE, **MAIN, **SCOPE, **CONCEPTS[name], **ovr}
    tv = base.pop("TV")
    def J(path, *ds):
        d = dict(base)
        for x in ds: d.update(x)
        return {"c":16,"v":7,"out":path,"d":{**d,"TV":str(tv)}}
    n = f"{out}/scope-{name}"
    os.makedirs(out, exist_ok=True)
    jobs = [J(f"{n}-1024.png", {"GSA":0.38})]
    if full:
        jobs += [J(f"{n}-src-mid.png", MID), J(f"{n}-src-32.png", H32, S32D, s32 or {}), J(f"{n}-src-16.png", H16, S16D, s16 or {})]
    os.makedirs('work', exist_ok=True)
    jf = f"work/j-{name}.json"; json.dump(jobs, open(jf,'w'), indent=1)
    env = {**os.environ, 'LOGO_HTML':'icon-signal.html'}
    subprocess.run(['node','src/render2.mjs',jf], check=True, env=env, stdout=subprocess.DEVNULL)
    if not full: return
    B = [f"{n}-1024.png:512:{n}-512.png", f"{n}-1024.png:256:{n}-256.png", f"{n}-src-mid.png:128:{n}-128.png",
         f"{n}-src-mid.png:64:{n}-64.png", f"{n}-src-32.png:32:{n}-32.png", f"{n}-src-16.png:16:{n}-16.png"]
    subprocess.run(['node','src/box.mjs',*B], check=True, stdout=subprocess.DEVNULL, env=env)
    M={"icon_16x16":16,"icon_16x16@2x":32,"icon_32x32":32,"icon_32x32@2x":64,"icon_128x128":128,"icon_128x128@2x":256,"icon_256x256":256,"icon_256x256@2x":512,"icon_512x512":512,"icon_512x512@2x":1024}
    d=f"{n}.iconset"; shutil.rmtree(d,ignore_errors=True); os.makedirs(d)
    for k,s in M.items(): shutil.copy(f"{n}-{s}.png", f"{d}/{k}.png")
    subprocess.run(['iconutil','-c','icns',d,'-o',f'{n}.icns'], check=True)
if __name__ == '__main__':
    name = sys.argv[1]
    takes = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'final-takes.json')))
    o, s16, s32 = takes.get(name, ({}, {}, {}))
    build(name, {**o, **json.loads(os.environ.get('OVR','{}'))}, {**s16, **json.loads(os.environ.get('S16','{}'))}, {**s32, **json.loads(os.environ.get('S32','{}'))},
          os.environ.get('OUT','masters'), os.environ.get('FULL','1')=='1')
