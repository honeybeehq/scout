import json, subprocess, os, shutil, sys
from gen import BASE, H16, H32, MID
MAIN = {"PR":0.21,"PL":0.29,"PG":1.35,"PHALO":1.9,"PCORE":0.22,"PBL":0.24,"PBASE":0.40,"PSPAN":0.28,"PHW":0.9,"PTOP":0.4,"EF_G":0.56,"EF_B":0.58,"PRIM":0.35,"PE":0.005,"PCY":0.04,"BT_R":0.36,"BT_G":0.19,"BT_B":0.10,"BB_R":0.18,"BB_G":0.08,"BB_B":0.045,"DG":0.8,"BTAPER":0.04,"BSOFT":10,"BFADE":0.30,"BGRAD":0.12,"BPULSE":0.20,"BPY":0.03,"BPW":0.5,"BEND":0.6}
S16 = json.loads(os.environ.get('S16','{}')) or {"SPC":0.5,"SPX":0.5,"SPW":2.5,"SPH":4.5,"SPR":2.5,"SLO":0.47,"SSPAN":0.30,"SGAIN":2.0,"SHALO":0.3,"SHW":0.6,"SFADE":0.22}
S32 = json.loads(os.environ.get('S32','{}')) or {"SPC":0.0,"SPX":0.5,"SPW":3.5,"SPH":7.0,"SPR":3.5,"SLO":0.47,"SSPAN":0.34,"SGAIN":1.85,"SHALO":0.6,"SHW":1.0,"SFADE":0.22}
n = sys.argv[1] if len(sys.argv) > 1 else 'scout-signal'
MAIN = {**MAIN, **json.loads(os.environ.get('OVR','{}'))}
def J(out, *ds):
    d = {**BASE, **MAIN}
    for x in ds: d.update(x)
    return {"c":15,"v":7,"out":out,"d":d}
jobs = [J(f"masters/{n}-1024.png", {"GSA":0.38}), J(f"masters/{n}-src-mid.png", MID),
        J(f"masters/{n}-src-32.png", H32, S32), J(f"masters/{n}-src-16.png", H16, S16)]
json.dump(jobs, open('work/jfinal.json','w'), indent=1)
env = {**os.environ, 'LOGO_HTML':'icon-signal.html'}
subprocess.run(['node','src/render2.mjs','work/jfinal.json'], check=True, env=env)
B = [f"masters/{n}-1024.png:512:masters/{n}-512.png", f"masters/{n}-1024.png:256:masters/{n}-256.png",
     f"masters/{n}-src-mid.png:128:masters/{n}-128.png", f"masters/{n}-src-mid.png:64:masters/{n}-64.png",
     f"masters/{n}-src-32.png:32:masters/{n}-32.png", f"masters/{n}-src-16.png:16:masters/{n}-16.png"]
subprocess.run(['node','src/box.mjs',*B], check=True, stdout=subprocess.DEVNULL, env=env)
M={"icon_16x16":16,"icon_16x16@2x":32,"icon_32x32":32,"icon_32x32@2x":64,"icon_128x128":128,"icon_128x128@2x":256,"icon_256x256":256,"icon_256x256@2x":512,"icon_512x512":512,"icon_512x512@2x":1024}
d=f"masters/{n}.iconset"; shutil.rmtree(d,ignore_errors=True); os.makedirs(d)
for k,s in M.items(): shutil.copy(f"masters/{n}-{s}.png", f"{d}/{k}.png")
subprocess.run(['iconutil','-c','icns',d,'-o',f'masters/{n}.icns'], check=True)
