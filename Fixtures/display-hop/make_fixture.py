import json
import os
import subprocess
import sys

if len(sys.argv) != 2:
    sys.exit("usage: make_fixture.py <output dir>")
out = os.path.abspath(sys.argv[1])
os.makedirs(out, exist_ok=True)

VW, VH = 1600, 1000
A = {"id": 1, "bounds": (0, 0, 1600, 1000)}
B = {"id": 2, "bounds": (1600, -100, 1280, 1024)}
hop = 5.0
total = 11.0

pay = (300, 400, 200, 60)
card = (2240, 400, 300, 80)

fit = min(VW / B["bounds"][2], VH / B["bounds"][3])
content_w, content_h = round(B["bounds"][2] * fit), round(B["bounds"][3] * fit)
bar_x = (VW - content_w) // 2
card_local = (round((card[0] - B["bounds"][0]) * fit), round((card[1] - B["bounds"][1]) * fit), round(card[2] * fit), round(card[3] * fit))

a = f"color=c=0xe8eaf0:s={VW}x{VH}:d={hop}:r=30,drawbox=x=0:y=0:w={VW}:h=70:color=0x2b2f3a:t=fill,drawbox=x={pay[0]}:y={pay[1]}:w={pay[2]}:h={pay[3]}:color=0xe0403a:t=fill"
b = f"color=c=0xdfe8f5:s={content_w}x{content_h}:d={total - hop}:r=30,drawbox=x=0:y=0:w={content_w}:h=60:color=0x26324a:t=fill,drawbox=x={card_local[0]}:y={card_local[1]}:w={card_local[2]}:h={card_local[3]}:color=0x3a62e0:t=fill,pad={VW}:{VH}:{bar_x}:0:black"
subprocess.run([
    "ffmpeg", "-y", "-loglevel", "error",
    "-f", "lavfi", "-i", a, "-f", "lavfi", "-i", b,
    "-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0,format=yuv420p[v]", "-map", "[v]",
    "-c:v", "libx264", "-preset", "veryfast", "-movflags", "+faststart", os.path.join(out, "screen.mp4"),
], check=True)

sentences = [
    (0.4, "Okay, a quick look at the checkout."),
    (2.0, "This red Pay now button is far too small."),
    (6.0, "On the other screen, the card number field is blue and should be wider."),
]
parts = []
for index, (start, sentence) in enumerate(sentences):
    aiff = os.path.join(out, f"s{index}.aiff")
    subprocess.run(["say", "-v", "Samantha", "-o", aiff, sentence], check=True)
    parts.append((aiff, start))
inputs = []
filters = []
for index, (aiff, start) in enumerate(parts):
    inputs += ["-i", aiff]
    delay = int(start * 1000)
    filters.append(f"[{index}:a]adelay={delay}|{delay}[a{index}]")
filters.append("".join(f"[a{i}]" for i in range(len(parts))) + f"amix=inputs={len(parts)}:normalize=0,apad=whole_dur={total}[mix]")
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex", ";".join(filters), "-map", "[mix]", "-ar", "16000", "-sample_fmt", "s16", "-ac", "1", os.path.join(out, "narration.wav")], check=True)
for aiff, _ in parts:
    os.remove(aiff)
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", f"anoisesrc=color=pink:amplitude=0.25:duration={total}", "-ar", "16000", "-sample_fmt", "s16", "-ac", "1", os.path.join(out, "noise.wav")], check=True)


def rect(r):
    return {"x": r[0], "y": r[1], "width": r[2], "height": r[3]}


context = {"app": {"bundleID": "com.example.shop", "name": "Shop"}, "windowTitle": "Checkout", "location": "http://shop.localhost:5173/checkout"}
signals = [
    {"type": "context", "at": 0.05, "context": context},
    {"type": "mark", "id": "m1", "at": 2.6, "point": {"x": pay[0] + 100, "y": pay[1] + 30}, "target": {"id": "ax-pay", "provider": "accessibility", "role": "AXButton", "label": "Pay now", "frame": rect(pay), "ancestry": []}},
    {"type": "mark", "id": "m2", "at": 7.6, "point": {"x": card[0] + 150, "y": card[1] + 40}, "target": {"id": "ax-card", "provider": "accessibility", "role": "AXTextField", "label": "Card number", "frame": rect(card), "ancestry": []}},
]
scopes = [{"at": hop, "scope": "screen", "bounds": rect(B["bounds"]), "byUser": False}]
displays = [{"id": d["id"], "bounds": rect(d["bounds"])} for d in (A, B)]
base = {"video": "screen.mp4", "screen": rect(A["bounds"]), "signals": signals, "scopes": scopes, "displays": displays, "hops": [{"at": hop, "display": B["id"]}]}
with open(os.path.join(out, "session.json"), "w") as handle:
    json.dump({"audio": "narration.wav", **base}, handle, indent=2)
with open(os.path.join(out, "noise.json"), "w") as handle:
    json.dump({"audio": "noise.wav", **base}, handle, indent=2)
expected = {
    "hop": hop,
    "displays": {str(d["id"]): d["bounds"] for d in (A, B)},
    "pins": {"m1": {"display": A["id"], "target": pay}, "m2": {"display": B["id"], "target": card}},
    "videoContentRectB": [bar_x, 0, content_w, content_h],
    "cardInVideo": [bar_x + card_local[0], card_local[1], card_local[2], card_local[3]],
}
with open(os.path.join(out, "expected.json"), "w") as handle:
    json.dump(expected, handle, indent=2)
print(json.dumps(expected))
