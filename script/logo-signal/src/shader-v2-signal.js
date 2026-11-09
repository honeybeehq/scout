const FRAG = String.raw`
out vec4 O;
const float PI = 3.14159265;
const float T = GT;
const vec2 FH = vec2(GW, GW - GT*0.5);
const vec2 FC = vec2(0.0, GCY + GT*0.5);
const float RAD = GR*1.528;
const float SC = 392.0*GK;
const float SQN = 3.3;

float hash(vec2 p){ p = fract(p*vec2(123.34, 456.21)); p += dot(p, p+45.32); return fract(p.x*p.y); }
float vnoise(vec2 p){ vec2 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
  return mix(mix(hash(i),hash(i+vec2(1,0)),f.x), mix(hash(i+vec2(0,1)),hash(i+vec2(1,1)),f.x), f.y); }
float fbm(vec2 p){ float a=0.5, s=0.0; for(int i=0;i<4;i++){ s+=a*vnoise(p); p*=2.03; a*=0.5; } return s; }
float sdRBox(vec2 p, vec2 b, float r){ vec2 q = abs(p) - b + r; vec2 m = max(q,0.0);
  float ln = pow(pow(m.x,SQN)+pow(m.y,SQN), 1.0/SQN);
  vec2 gr = ln > 1e-4 ? pow(m/ln, vec2(SQN-1.0)) : vec2(0.7071);
  float gl = max(length(gr), 0.5);
  float outer = (ln - r)/gl;
  return max(q.x,q.y) <= 0.0 ? max(q.x,q.y) - r : (min(q.x,q.y) <= 0.0 ? max(q.x,q.y) - r : outer); }
float sdFace(vec2 P){ return sdRBox(P - FC, FH, RAD); }
float sdSil(vec2 P){ return sdRBox(P - FC + vec2(0.0, T*0.5), FH + vec2(0.0, T*0.5), RAD); }
vec2 gradFace(vec2 P){ float e=1.0; return normalize(vec2(sdFace(P+vec2(e,0))-sdFace(P-vec2(e,0)), sdFace(P+vec2(0,e))-sdFace(P-vec2(0,e))) + 1e-6); }
mat2 rot(float a){ float c=cos(a), s=sin(a); return mat2(c,-s,s,c); }
float sdHex(vec2 p, float r){ const vec3 k=vec3(-0.866025404,0.5,0.577350269); p=abs(p); p-=2.0*min(dot(k.xy,p),0.0)*k.xy; p-=vec2(clamp(p.x,-k.z*r,k.z*r),r); return length(p)*sign(p.y); }
float sdHexP(vec2 p, float r){ return sdHex(p.yx, r); }
float sdSeg(vec2 p, vec2 a, vec2 b){ vec2 pa=p-a, ba=b-a; float h=clamp(dot(pa,ba)/dot(ba,ba),0.0,1.0); return length(pa-ba*h); }
float sdBox(vec2 p, vec2 b, float r){ vec2 d = abs(p) - b + r; return length(max(d,0.0)) + min(max(d.x,d.y),0.0) - r; }
float sstep(float a, float b, float x){ return smoothstep(a,b,x); }
float luma(vec3 c){ return dot(c, vec3(0.2126,0.7152,0.0722)); }

vec3 ember(float t){
  t = clamp(t,0.0,1.0);
  vec3 c0=vec3(0.30,0.03,0.03), c1=vec3(0.66,0.10,0.04), c2=vec3(0.93,0.33,0.06), c3=vec3(1.0,0.62,0.12), c4=vec3(1.0,0.76,0.28), c5=vec3(1.0,0.90,0.62);
  if(t<0.2) return mix(c0,c1,t/0.2);
  if(t<0.42) return mix(c1,c2,(t-0.2)/0.22);
  if(t<0.64) return mix(c2,c3,(t-0.42)/0.22);
  if(t<0.84) return mix(c3,c4,(t-0.64)/0.2);
  return mix(c4,c5,(t-0.84)/0.16);
}

vec3 coral(float t){
  t = clamp(t,0.0,1.0);
  vec3 c0=vec3(0.30,0.025,0.035), c1=vec3(0.68,0.07,0.05), c2=vec3(0.95,0.22,0.11), c3=vec3(1.0,0.36,0.21), c4=vec3(1.0,0.46,0.33), c5=vec3(1.0,0.64,0.58);
  if(t<0.2) return mix(c0,c1,t/0.2);
  if(t<0.42) return mix(c1,c2,(t-0.2)/0.22);
  if(t<0.64) return mix(c2,c3,(t-0.42)/0.22);
  if(t<0.84) return mix(c3,c4,(t-0.64)/0.2);
  return mix(c4,c5,(t-0.84)/0.16);
}

struct Lay { vec3 col; float a; vec3 emit; };
void over(inout Lay L, vec3 c, float a){ L.col = mix(L.col, c, a*(1.0-0.0)); L.a = max(L.a, a); }

vec3 baseTop, baseBot, sideTint; vec3 emitF = vec3(1.0); float darkGlass, frostAmt, refr;

void material(){
#if C==3
  baseTop=vec3(0.66,0.37,0.08); baseBot=vec3(0.42,0.15,0.03); sideTint=vec3(1.0,0.55,0.10); darkGlass=0.5; frostAmt=0.7; refr=1.2; emitF=vec3(1.0,0.66,0.42);
#elif C==6
  baseTop=vec3(0.20,0.11,0.05); baseBot=vec3(0.10,0.045,0.02); sideTint=vec3(1.0,0.55,0.12); darkGlass=1.0; frostAmt=0.6; refr=1.2;
#elif C==15
  baseTop=vec3(BT_R,BT_G,BT_B); baseBot=vec3(BB_R,BB_G,BB_B); sideTint=vec3(1.0,0.40,0.20); darkGlass=DG; frostAmt=0.65; refr=1.2; emitF=vec3(1.0,EF_G,EF_B);
#endif
}

float hUp=0.0, lipOld=0.0, hEdge=-1.0, hGrad=-1.0, hHaloW=-1.0, hBloom=0.0, hFacet=0.0, hRim=0.0, hCore=0.0, hTop=0.0, hRound=0.07;
float kSoft=1.0, kSize=1.0, kGain=1.0, kWarm=0.0, kHalo=1.0, kLine=1.0, kDof=0.0, kLift=0.0;
float scat=0.0, inLine=1.0, inW=2.4, inPos=24.0, bevW=26.0, specK=1.0, vigK=1.0, grainK=1.0, veil=0.0, sideK=1.0, edgeDark=0.0, refrK=1.0, lipK=0.0;
vec3 baseMul=vec3(1.0), veilCol=vec3(1.0,0.94,0.84);
float pk=1.0, specW=1.0;

void tune(){
#if V>0
  inLine=0.55; inW=4.0; lipK=0.06; grainK=1.6;
#endif
#if C==3
#if V>=4
  kSize=1.05; kGain=1.10; kSoft=0.9; vigK=1.6; edgeDark=0.22; baseMul=vec3(0.92,0.86,0.82); inLine=0.4; lipOld=1.0; lipK=0.10;
#if V==7
  hEdge=0.006; hGrad=1.0; hHaloW=0.8; hBloom=0.20; hTop=0.28; hRim=0.20; hCore=0.12; hRound=0.06; kGain=1.02;
#endif
#endif
#if SMALL>=2
  kSize = (HAPO*PXS/SC)/0.46; hEdge=0.004; kHalo=HHALO; hBloom=HBLOOM; hTop=0.20; hRim=0.0; hCore=0.10; kGain=HGAIN; edgeDark=0.30;
  pk=PXS/20.0; specW=2.2; inLine=0.0; lipK=0.0; refrK=0.0; grainK=0.0;
#endif
#elif C==6
#if V>=4
  kSize=1.06; kGain=1.15; kLine=1.15; vigK=1.4; inLine=0.4; lipOld=1.0; lipK=0.10;
  hUp = float(V-3)*0.03*1024.0/392.0;
#endif
#elif C==15
  kSize=1.0; kGain=PG; kSoft=0.9; vigK=1.5; edgeDark=0.20; inLine=0.4; lipOld=1.0; lipK=0.10;
  hEdge=PE; hGrad=1.0; hHaloW=PHW; hBloom=PBL; hTop=PTOP; hRim=PRIM; hCore=PCORE; kHalo=PHALO;
#if SMALL>=2
  hEdge=0.004; hRim=0.0; edgeDark=0.30;
  pk=PXS/20.0; specW=2.2; inLine=0.0; lipK=0.0; refrK=0.0; grainK=0.0;
#endif
#endif
}

Lay interior(vec2 q){
  Lay L; L.col = vec3(0); L.a = 0.0; L.emit = vec3(0);
#if C==3
  vec2 p = q - vec2(0.0,0.03);
  float d = sdHexP(p, 0.40*kSize) - hRound*kSize;
  float t = clamp(-d/0.47, 0.0, 1.0);
  float eIn = hEdge < 0.0 ? 0.05*kSoft : hEdge;
  float eOut = hEdge < 0.0 ? 0.09*kSoft : hEdge*1.2;
  float cov = 1.0 - sstep(-eIn, eOut, d);
  float gp = hGrad < 0.0 ? 0.8*kSoft : hGrad;
  float hw = hHaloW < 0.0 ? kSoft : hHaloW;
  vec3 heat = ember(0.46 + kWarm + 0.36*pow(t,gp) + hTop*(p.y*0.6));
  float sa = atan(p.y, p.x);
  float sec = floor((sa + PI/6.0)/(PI/3.0));
  float sc = sec*PI/3.0;
  float facet = dot(vec2(cos(sc), sin(sc)), normalize(vec2(-0.35, 1.0)));
  heat *= 1.0 + hFacet*facet*sstep(0.0, 0.35, t)*(1.0 - sstep(0.55, 0.9, t));
  L.emit += heat * cov * 0.80 * kGain;
  L.emit += vec3(1.0,0.86,0.55) * hRim * cov * exp(-max(-d,0.0)/0.012) * (0.55 + 0.45*sstep(-0.3, 0.3, p.y));
  L.emit += vec3(1.0,0.45,0.08)*0.42*kHalo*exp(-max(d,0.0)*6.0/hw);
  L.emit += vec3(0.9,0.25,0.04)*0.25*kHalo*exp(-max(d,0.0)*2.5/hw);
  L.emit += vec3(1.0,0.55,0.12)*hBloom*exp(-max(d,0.0)*14.0);
  L.emit += vec3(1.0,0.90,0.62)*hCore*cov*exp(-dot(p-vec2(0.0,0.05),p-vec2(0.0,0.05))/0.06);
#elif C==15 && SMALL>=2
  vec2 u = (q*SC + FC)/PXS;
  float d = sdBox(u - vec2(SPX, SPC), vec2(SPW, SPH), SPR);
  float cov = 1.0 - sstep(-0.03, 0.03, d);
  float tv = clamp((u.y - SPC + SPH)/(2.0*SPH), 0.0, 1.0);
  float tx = 1.0 - abs(u.x - SPX)/SPW;
  float sEnd = sstep(0.55, 1.0, abs(u.y - SPC)/SPH);
  L.emit += coral(SLO + SSPAN*tv + 0.10*tx) * cov * SGAIN * (1.0 - SFADE*sEnd);
  L.emit += coral(0.40)*SHALO*exp(-max(d,0.0)/SHW) * (1.0 - cov);
#elif C==15
  vec2 p = q - vec2(0.0, PCY);
  float R = PR*kSize, Lh = PL*kSize;
  float along = clamp(abs(p.y)/(Lh+R), 0.0, 1.0);
  float endK = sstep(BEND, 1.0, along);
  float Ry = R*(1.0 - BTAPER*along*along);
  float d = sdSeg(p, vec2(0.0,-Lh), vec2(0.0,Lh)) - Ry;
  float t = clamp(-d/Ry, 0.0, 1.0);
  float e = hEdge*(1.0 + BSOFT*endK);
  float cov = 1.0 - sstep(-e, e*1.2, d);
  float glow = 1.0 - BFADE*endK;
  vec3 heat = coral(PBASE + PSPAN*pow(t,hGrad) + hTop*(p.y/(Lh+R))*0.5 + BGRAD*(1.0 - along));
  L.emit += heat * cov * 0.80 * kGain * glow;
  L.emit += vec3(1.0,0.80,0.68) * hRim * cov * exp(-max(-d,0.0)/0.012) * (0.55 + 0.45*sstep(-0.3, 0.3, p.y)) * (1.0 - endK);
  float pulse = exp(-pow((p.y - BPY)/(Lh*BPW), 2.0)) * exp(-p.x*p.x/(Ry*Ry*0.5));
  L.emit += coral(0.92) * BPULSE * cov * pulse;
  L.emit += vec3(1.0,0.36,0.16)*0.42*kHalo*exp(-max(d,0.0)*6.0/hHaloW);
  L.emit += vec3(0.88,0.16,0.08)*0.25*kHalo*exp(-max(d,0.0)*2.5/hHaloW);
  L.emit += vec3(1.0,0.45,0.25)*hBloom*exp(-max(d,0.0)*14.0);
  vec2 cp = p - vec2(0.0, PCO);
  L.emit += vec3(1.0,0.62,0.56)*hCore*cov*exp(-(cp.x*cp.x/(R*R*0.35) + cp.y*cp.y/(Lh*Lh*0.9)));
#elif C==6
  q.y -= hUp;
  for(int i=0;i<3;i++){
    float fi = float(i);
    vec2 c = vec2(0.0, -0.36 + fi*0.27)*kSize;
    float bl = 0.012*kSoft*(1.0 + kDof*(2.0-fi)*1.4);
    vec2 p = (q - c) * vec2(1.0, 1.75) / kSize;
    float d = sdHex(p, 0.50) - 0.05;
    float dside = sdHex((q - c + vec2(0.0,0.06)*kSize)*vec2(1.0,1.75)/kSize, 0.50) - 0.05;
    float sideCov = (1.0 - sstep(-bl,bl,dside)) * sstep(-bl, bl, d);
    vec3 tint = ember(0.30 + kWarm + 0.30*fi);
    float dim = 1.0 - kDof*(2.0-fi)*0.12;
    over(L, tint*0.9*dim, sideCov*0.95);
    L.emit += ember(0.46 + kWarm + 0.26*fi) * sideCov * 0.35 * kGain * dim;
    float cov = 1.0 - sstep(-bl, bl, d);
    float tt = clamp(-d/0.5,0.0,1.0);
    vec3 top = ember(0.34 + kWarm + 0.20*fi + 0.22*tt);
    over(L, top*0.62*dim, cov*0.80);
    L.emit += ember(0.45 + kWarm + 0.2*fi) * cov * (0.10 + 0.22*tt) * kGain * dim;
    float lw = 0.006*mix(1.0, kSoft, 0.6)*(1.0 + kDof*(2.0-fi)*1.2);
    L.emit += vec3(1.0,0.92,0.7) * exp(-abs(d+0.02)/lw) * 0.55 * kLine * cov * (0.4 + 0.6*sstep(-0.2,0.3,p.y)) * (0.006/lw*0.5+0.5);
    L.emit += vec3(1.0,0.5,0.1)*0.10*kHalo*exp(-max(d,0.0)*8.0/kHalo);
  }
#endif
  return L;
}

vec3 shadeFace(vec2 P){
  vec2 q = (P - FC)/SC;
  float e = -sdFace(P);
  vec2 g = gradFace(P);
  float bevel = 1.0 - sstep(0.0, bevW*pk, e);
  float edgeZone = 1.0 - sstep(0.0, 80.0*pk, e);
  vec2 qs = q - g*refr*refrK*0.05*pow(edgeZone,2.0);
  Lay L = interior(qs);
  if(scat > 0.0){
    vec3 se = vec3(0.0); vec3 sc = vec3(0.0); float sa = 0.0;
    float ws = 0.0;
    for(int k=0;k<20;k++){
      float fk = float(k) + 0.5;
      float rr = sqrt(fk/20.0)*0.11;
      float a = fk*2.39996;
      float w = exp(-rr*rr/(2.0*0.05*0.05));
      Lay Ls = interior(qs + rr*vec2(cos(a), sin(a)));
      se += Ls.emit*w; sc += Ls.col*Ls.a*w; sa += Ls.a*w; ws += w;
    }
    se /= ws; sc /= ws; sa /= ws;
    L.emit = mix(L.emit, se, scat);
    L.col = mix(L.col*L.a, sc, scat)/max(mix(L.a, sa, scat), 1e-3);
    L.a = mix(L.a, sa, scat);
  }
  float vy = (q.y + 1.0)*0.5;
  vec3 base = mix(baseBot, baseTop, sstep(0.0,1.0,vy))*baseMul;
  float fr = fbm(P*0.025)*0.5 + fbm(P*0.11)*0.5;
  base *= 1.0 + (fr-0.5)*0.05*frostAmt*grainK;
  vec3 col = mix(base, L.col*mix(vec3(1.0), emitF, 0.5), L.a*mix(1.0, 0.86, frostAmt*(1.0-darkGlass))) + L.emit*emitF;
  float vign = sstep(0.0, 140.0*pk, e);
  col *= mix(1.0 - (1.0 - mix(0.92, 0.72, darkGlass))*vigK, 1.0, vign);
  col *= 1.0 - edgeDark*exp(-pow((e-34.0*pk)/(22.0*pk), 2.0));
  float vl = luma(col);
  col = mix(col, mix(vec3(vl), col, 0.75)*0.9 + veilCol*0.22*(0.4+0.6*sstep(-0.8,0.9,q.y)), veil);
  Lay Ln = interior(q*0.82);
  vec3 nearLight = Ln.emit + Ln.col*Ln.a*0.6;
  float nl = dot(nearLight, vec3(0.3,0.5,0.2));
  vec3 rimTint = mix(sideTint, nearLight/max(nl,0.05)*0.5, 0.35);
  float bottomness = sstep(0.4, -0.9, g.y);
  col += rimTint * (0.25 + 1.1*nl) * (exp(-e/(12.0*pk)) + 0.35*exp(-e/(40.0*pk))) * mix(0.30, 1.0, bottomness) * 0.85;
  vec3 n = normalize(vec3(g * bevel * 1.4, 1.0));
  float lam = dot(n, normalize(vec3(-0.15, 0.75, 0.65)));
  col *= mix(1.0, 0.85 + 0.30*lam, bevel);
  float topness = sstep(-0.3, 0.9, g.y);
  float spec = exp(-pow((e-3.2*pk*specW)/(1.6*pk*specW), 2.0)) * (0.30 + 0.70*topness);
  col += vec3(1.0,0.98,0.94) * spec * mix(0.55, 0.85, darkGlass) * specK;
  float lip = exp(-pow((e-bevW*0.45)/(bevW*0.22), 2.0)) * pow(topness, 1.5);
  if(lipOld > 0.0) lip = exp(-pow((e-bevW*0.85)/(bevW*0.32), 2.0)) * (0.20 + 0.80*topness);
  col += mix(vec3(1.0,0.97,0.92), rimTint, lipOld > 0.0 ? 0.4 : 0.25) * lip * lipK;
  float inner = exp(-pow((e-inPos*pk)/(inW*pk), 2.0)) * (0.25 + 0.75*topness);
  col += vec3(1.0,0.97,0.92) * inner * mix(0.16, 0.30, darkGlass) * inLine;
  float sheen = sstep(0.15, 0.95, q.y) * (1.0 - sstep(0.0, 1.0, abs(q.x)*0.9)) ;
  col += vec3(1.0) * sheen * mix(0.025, 0.06, darkGlass);
  return col;
}

vec3 shadeSide(vec2 P){
  float v = clamp(sdFace(P)/T, 0.0, 1.0);
  vec2 q = (P - FC)/SC;
  float u = clamp(q.x/1.03, -1.0, 1.0);
  vec3 nearLight = vec3(0); float wsum = 0.0;
  for(int k=0;k<15;k++){
    float uk = (float(k)-7.0)/7.0;
    float wk = exp(-pow((u-uk)/0.16, 2.0));
    Lay Ln = interior(vec2(uk*0.88, -0.78));
    Lay Lm = interior(vec2(uk*0.55, -0.40));
    nearLight += wk*(min(Ln.emit, vec3(1.2)) + Ln.col*Ln.a*0.7 + 0.5*(min(Lm.emit, vec3(1.2)) + Lm.col*Lm.a*0.5));
    wsum += wk;
  }
  nearLight /= wsum;
  float nl = dot(nearLight, vec3(0.3,0.5,0.2));
  vec3 lightCol = nl > 0.001 ? nearLight/nl : sideTint;
  vec3 tint = mix(sideTint, lightCol*0.6, 0.35);
  float corner = pow(abs(u), 5.0);
  float body = (0.30 + 1.15*nl + 0.9*corner)*sideK;
  vec3 col = tint * body;
  col *= mix(0.55, 1.0, darkGlass*0.0 + 1.0);
  col += mix(baseBot, vec3(0.0), darkGlass) * 0.25 * (1.0 - darkGlass);
  float streak1 = exp(-pow((v-0.12)/0.06, 2.0));
  float streak2 = exp(-pow((v-0.55)/0.10, 2.0));
  col += vec3(1.0,0.95,0.80) * streak1 * (0.35 + 0.65*nl) * 0.6;
  col += tint * streak2 * (0.25 + 0.6*corner) * 0.55;
#if MUD==1
  col *= mix(vec3(1.0), vec3(0.94,0.76,0.52), sstep(0.72, 1.0, v));
  col += vec3(1.0,0.86,0.55) * exp(-pow((v-0.90)/0.03,2.0)) * 0.22;
  col = mix(vec3(luma(col)), col, 1.0 + 0.18*sstep(0.6, 1.0, v));
#else
  col *= mix(1.0, 0.55, sstep(0.75, 1.0, v));
  col += vec3(1.0,0.9,0.7) * exp(-pow((v-0.93)/0.035,2.0)) * 0.18;
#endif
  col += (vnoise(vec2(P.x*0.02, v*40.0)) - 0.5) * 0.06 * tint;
  return col;
}

vec3 tone(vec3 c){
  c = max(c, 0.0);
  vec3 k = 0.76 + 0.24*(1.0 - exp(-(c - 0.76)/0.24));
  return mix(c, k, step(0.76, c));
}

void main(){
  vec2 frag = gl_FragCoord.xy * (1024.0/RES);
  float px = 1024.0/RES;
  material();
  tune();
  vec3 acc = vec3(0); float aacc = 0.0; float sh = 0.0;
  vec2 offs[4] = vec2[4](vec2(0.125,0.375), vec2(0.375,-0.125), vec2(-0.125,-0.375), vec2(-0.375,0.125));
  for(int s=0;s<4;s++){
    vec2 fp = frag + offs[s]*px;
    vec2 P = vec2(fp.x - 512.0, fp.y - 512.0);
    float ds = sdSil(P);
    float cov = clamp(0.5 - ds/px, 0.0, 1.0);
    vec3 col = vec3(0);
    if(cov > 0.0){
      float df = sdFace(P);
      vec3 cf = shadeFace(P);
      vec3 cs = shadeSide(P);
      float fcov = clamp(0.5 - df/px, 0.0, 1.0);
      col = mix(cs, cf, fcov);
      col = tone(col);
      col += (hash(fp*1.37 + float(s)) - 0.5) * 0.022;
    }
    acc += col * cov; aacc += cov;
  }
  vec3 c = acc/4.0; float a = aacc/4.0;
  vec2 P0 = frag - 512.0;
  float dsh = sdSil(P0 + vec2(0.0, GSY));
  float shA = GSA * (1.0 - sstep(-GSB, GSB, dsh));
  float outA = a + shA*(1.0 - a);
  O = vec4(c, outA);
}
`;
