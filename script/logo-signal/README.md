# Scout "Signal" app icon

Chris's WebGL2 family renderer (honeybeehq/apiary `.proof/icon-v2/src`) with one added concept, `C==15`: a single glowing ember-coral pill on the dark family slab. Only `material()`, `tune()`, `interior()` and a new `coral()` ramp differ; slab, bevel, bottom band and lighting are the family's. Unused concept branches were trimmed; Apiary `c:3 v:7` still renders identically (max channel difference 5 from noise).

Needs Node 24+, Python 3 and Google Chrome. No packages.

```sh
cd script/logo-signal
export LOGO_CHROME='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
mkdir -p work masters
python3 final.py
```

It renders `masters/scout-signal-{1024,512,256,128,64,32,16}.png`, a `.iconset` and `.icns`. 16 and 32 px are rendered at 1024 with `SMALL=2` (pill snapped to output pixels via `SPX/SPC/SPW/SPH/SPR`; `SPX 0.5` shifts the pill half a pixel so an odd width lands on whole pixels) and box-averaged. The job list of the last build is written to `work/jfinal.json`; `work/` and `masters/` are not committed. Chrome runs headless with a throwaway profile under /tmp.

Main defines: `PR 0.21 PL 0.29` (pill radius and half-length in face units), `PCY 0.04`, `PG 1.35`, `PHALO 1.9`, `PCORE 0.22`, `PBL 0.24`, `PBASE 0.40 PSPAN 0.28`, `PTOP 0.4`, `PRIM 0.35`, `PE 0.005`, slab `BT 0.36/0.19/0.10`, `BB 0.18/0.08/0.045`, `DG 0.8`, `EF 1/0.56/0.58` (emission filter pulled toward pink so the core reads ember-coral, not cream-amber beside Apiary). The coral ramp's top stops are pinker: `c4 1/0.46/0.33`, `c5 1/0.64/0.58`, core tint `1/0.62/0.56`. Slab body mean luminance is 81 (Honeybee 85.5, Apiary 114); the pill core is about #FFB46B and the pill middle about #FF8143; round 2 was 65 and read a stop darker and more maroon.

Small sizes (round 3): 16 px pill 5×9 px (`SPX 0.5 SPC 0.5 SPW 2.5 SPH 4.5 SPR 2.5`, `SLO 0.47 SSPAN 0.30 SGAIN 2.0`, halo cut to `SHALO 0.3 SHW 0.6`); 32 px pill 7×14 px (`SPX 0.5 SPC 0 SPW 3.5 SPH 7 SPR 3.5`, `SLO 0.47 SSPAN 0.34 SGAIN 1.85 SHALO 0.6 SHW 1.0`). `final.py` accepts `OVR`, `S16` and `S32` JSON env overrides for experiments.

Beam softening (Chris's family-fit note, so the beam reads as light rather than a toggle, battery or capital "I"): `BEND 0.6` keeps the middle 60 % of the beam's edge as crisp as Apiary's hexagon; beyond it the edge blurs (`BSOFT 10`), the glow fades (`BFADE 0.30`), the rim fades out and the beam tapers slightly (`BTAPER 0.04`). A hot inner core lifts the centre (`BGRAD 0.12`, `BPULSE 0.20` at `BPY 0.03`, `BPW 0.5`). The 16 and 32 px pills fade their end pixels slightly (`SFADE 0.22`).

Install into the app: copy `masters/scout-signal.iconset/icon_<n>x<n>.png` to `mac/Scout/Resources/Assets.xcassets/AppIcon.appiconset/icon_<n>x<n>@1x.png` and the `@2x` files as they are.
