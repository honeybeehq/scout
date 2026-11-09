import json, sys, subprocess, os
BASE = dict(BT_R=0.20, BT_G=0.085, BT_B=0.06, BB_R=0.10, BB_G=0.035, BB_B=0.03, DG=1.0, EF_G=0.85, EF_B=0.80,
            PG=1.02, PE=0.006, PHW=0.8, PBL=0.20, PTOP=0.28, PRIM=0.20, PCORE=0.12, PHALO=1.0,
            PCY=0.03, PR=0.15, PL=0.36, PBASE=0.46, PSPAN=0.36, PCO=0.06,
            SPC=0.5, SPX=0.0, SPW=2.0, SPH=4.0, SPR=2.0, SLO=0.50, SSPAN=0.35, SGAIN=1.0, SHALO=0.25, SHW=0.8, GSA=0.38,
            BTAPER=0.0, BSOFT=0.0, BFADE=0.0, BGRAD=0.0, BPULSE=0.0, BPY=0.0, BPW=0.5, SFADE=0.0, BEND=0.35)
H16={"GW":448,"GT":64,"GR":201.6,"GK":1.0612,"GSY":40,"GSB":48,"GSA":0.35,"SMALL":2,"PXS":64}
H32={"GW":416,"GT":64,"GR":187.2,"GK":0.9796,"GSY":20,"GSB":28,"GSA":0.38,"SMALL":2,"PXS":32}
MID={"GW":416,"GT":47.5,"GR":187.2,"GK":(416-23.75)/392,"GSY":10,"GSB":28,"GSA":0.38}
def job(out, **kw):
    d = {**BASE, **kw}
    return {"c":15, "v":7, "out":out, "d":d}
if __name__ == '__main__':
    spec = json.load(open(sys.argv[1]))
    jobs = [job(o, **kw) for o, kw in spec]
    json.dump(jobs, open('work/jobs.json','w'), indent=1)
    subprocess.run(['node','src/render2.mjs','work/jobs.json'], check=True, env={**os.environ, 'LOGO_HTML':'icon-signal.html'})
