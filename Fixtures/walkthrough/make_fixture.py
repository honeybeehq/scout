import json
import math
import os
import subprocess
import sys
import tempfile

if len(sys.argv) != 2:
    sys.exit("usage: make_fixture.py <output dir>")
out = os.path.abspath(sys.argv[1])
profile = tempfile.mkdtemp(prefix="scout-fixture-chrome-")
os.makedirs(out, exist_ok=True)
chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
W, H = 1440, 900

sentences = [
    "Okay, quick walkthrough of the checkout.",
    "This Pay now button is way too small. Make it full width, primary style.",
    "In the card number field, errors only show after I submit. Show them inline while I type.",
    "And the summary says shipping is free over forty euros, but the page charges four ninety. Check which one is right.",
    "That's it.",
]
gap = 0.9
parts = []
starts = []
t = 0.4
for index, sentence in enumerate(sentences):
    aiff = os.path.join(out, f"s{index}.aiff")
    subprocess.run(["say", "-v", "Samantha", "-o", aiff, sentence], check=True)
    duration = float(subprocess.run(["afinfo", "-b", aiff], capture_output=True, text=True).stdout.split(" sec")[0].split()[-1])
    starts.append((t, t + duration))
    parts.append((aiff, duration))
    t += duration + gap
total = t + 0.5

filters = []
inputs = []
for index, (aiff, _) in enumerate(parts):
    inputs += ["-i", aiff]
    delay = int(starts[index][0] * 1000)
    filters.append(f"[{index}:a]adelay={delay}|{delay}[a{index}]")
filters.append("".join(f"[a{i}]" for i in range(len(parts))) + f"amix=inputs={len(parts)}:normalize=0,apad=whole_dur={total}[mix]")
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex", ";".join(filters), "-map", "[mix]", "-ar", "16000", "-sample_fmt", "s16", "-ac", "1", os.path.join(out, "narration.wav")], check=True)
for aiff, _ in parts:
    os.remove(aiff)

pay = (1004, 560, 92, 30)
card = (860, 330, 380, 40)
shipping = (860, 470, 380, 28)

page = """<!doctype html><html><head><meta charset=utf-8><style>
body{margin:0;width:1440px;height:900px;font:15px -apple-system,Helvetica;background:#eceef2;color:#1d2230}
.bar{height:76px;background:#2b2f3a;color:#cfd3dc;display:flex;align-items:center;padding:0 24px;gap:12px;font-size:13px}
.url{flex:1;background:#3a3f4c;border-radius:8px;padding:8px 14px;color:#e8eaf0}
.col{position:absolute;left:840px;top:110px;width:420px;background:#fff;border-radius:14px;padding:20px;box-shadow:0 2px 10px #0001;height:520px}
.items{position:absolute;left:180px;top:110px;width:600px;background:#fff;border-radius:14px;padding:24px;height:600px}
.item{display:flex;justify-content:space-between;padding:16px 0;border-bottom:1px solid #eef}
h2{margin:0 0 18px;font-size:20px}
.field{position:absolute;left:20px;top:220px;width:376px;height:36px;border:2px solid #c9cdd6;border-radius:8px;padding-left:10px;line-height:36px;color:#999}
.focus .field{border-color:#5b7cfa;color:#111}
.label{position:absolute;left:20px;top:194px;font-size:13px;color:#555}
.ship{position:absolute;left:20px;top:360px;width:380px;height:28px;display:flex;justify-content:space-between;align-items:center}
.total{position:absolute;left:20px;top:400px;width:380px;display:flex;justify-content:space-between;font-weight:600}
.pay{position:absolute;left:164px;top:450px;width:92px;height:30px;font-size:12px;border:1px solid #bbb;background:#f6f6f6;border-radius:6px}
.note{position:absolute;left:20px;top:60px;width:380px;background:#eef6ee;color:#265c2a;border-radius:8px;padding:10px;font-size:13px}
svg{position:absolute;left:0;top:0}
</style></head><body class="STATE"><div class=bar>● ● ●<div class=url>shop.localhost:5173/checkout</div></div>
<div class=items><h2>Your order</h2><div class=item><span>Trail runner, size 43</span><span>89.00 €</span></div><div class=item><span>Wool socks (2)</span><span>18.00 €</span></div><div class=item><span>Water bottle</span><span>12.50 €</span></div></div>
<div class=col><h2>Payment</h2><div class=note>Free shipping on orders over 40 €</div><div class=label>Card number</div><div class=field>CARD</div>
<div class=ship><span>Shipping</span><span>4.90 €</span></div><div class=total><span>Total</span><span>124.40 €</span></div><button class=pay>Pay now</button></div>
INK</body></html>"""

def ellipse(cx, cy, rx, ry, n=28, t0=0.0, t1=1.0):
    return [(cx + rx * math.cos(2 * math.pi * k / n - math.pi / 2), cy + ry * math.sin(2 * math.pi * k / n - math.pi / 2), t0 + (t1 - t0) * k / n) for k in range(n + 1)]

stroke_start = starts[3][0] + 1.6
stroke_end = stroke_start + 1.1
ring = ellipse(shipping[0] + shipping[2] / 2, shipping[1] + shipping[3] / 2, shipping[2] / 2 + 18, shipping[3] / 2 + 14, t0=stroke_start, t1=stroke_end)
ink = '<svg width=1440 height=900><path d="M' + " L".join(f"{x:.0f} {y:.0f}" for x, y, _ in ring) + '" fill=none stroke="#ff6a3d" stroke-width=4 stroke-linecap=round /></svg>'

states = {
    "a": page.replace("STATE", "").replace("CARD", "1234 5678 9012 3456").replace("INK", ""),
    "b": page.replace("STATE", "focus").replace("CARD", "4242 42").replace("INK", ""),
    "c": page.replace("STATE", "focus").replace("CARD", "4242 42").replace("INK", ink),
}
for name, html in states.items():
    path = os.path.join(out, f"state-{name}.html")
    with open(path, "w") as handle:
        handle.write(html)
    subprocess.run([chrome, "--headless=new", "--no-sandbox", "--disable-gpu", "--disable-crash-reporter", f"--user-data-dir={profile}", "--hide-scrollbars", f"--window-size={W},{H}", f"--screenshot={os.path.join(out, f'state-{name}.png')}", f"file://{path}"], check=True, capture_output=True)
    os.remove(path)

change_b = starts[2][0] + 0.3
segments = [("a", change_b), ("b", stroke_end - change_b), ("c", total - stroke_end)]
concat = os.path.join(out, "states.txt")
with open(concat, "w") as handle:
    for name, duration in segments:
        handle.write(f"file 'state-{name}.png'\nduration {duration:.3f}\n")
    handle.write(f"file 'state-{segments[-1][0]}.png'\n")
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", concat, "-vf", "fps=30,format=yuv420p", "-c:v", "libx264", "-preset", "veryfast", "-movflags", "+faststart", "-t", f"{total:.3f}", os.path.join(out, "screen.mp4")], check=True)
os.remove(concat)

def rect(r):
    return {"x": r[0], "y": r[1], "width": r[2], "height": r[3]}

chrome_app = {"bundleID": "com.google.Chrome", "name": "Google Chrome"}
context = {"app": chrome_app, "windowTitle": "Checkout · Shop", "location": "http://shop.localhost:5173/checkout", "project": {"rootPath": "/Users/test/shop", "name": "shop", "gitBranch": "main"}}
pin1 = starts[1][0] + 1.0
pin2 = starts[2][0] + 1.4
signals = [
    {"type": "context", "at": 0.05, "context": context},
    {"type": "focus", "range": {"start": starts[0][0] + 0.5, "end": starts[0][0] + 1.8}, "target": {"id": "ax-items", "provider": "accessibility", "role": "AXGroup", "label": "Your order", "frame": rect((180, 110, 648, 648)), "ancestry": []}},
    {"type": "mark", "id": "m1", "at": pin1, "point": {"x": pay[0] + 40, "y": pay[1] + 14}, "target": {"id": "web-pay", "provider": "web", "role": "button", "label": "Pay now", "frame": rect(pay), "ancestry": ["form#payment"], "component": "PayButton", "selector": "button.pay-now", "source": {"file": "src/checkout/PayButton.tsx", "line": 42}}},
    {"type": "visualChange", "at": change_b, "magnitude": 0.31},
    {"type": "mark", "id": "m2", "at": pin2, "point": {"x": card[0] + 120, "y": card[1] + 20}, "target": {"id": "ax-card", "provider": "accessibility", "role": "AXTextField", "label": "Card number", "frame": rect(card), "ancestry": ["AXWebArea"]}},
    {"type": "visualChange", "at": stroke_start + 0.4, "magnitude": 0.08},
]
strokes = [{"start": stroke_start, "end": stroke_end, "points": [[round(x, 1), round(y, 1), round(t, 3)] for x, y, t in ring], "color": "#ff6a3d", "width": 4}]
fixture = {"audio": "narration.wav", "video": "screen.mp4", "screen": rect((0, 0, W, H)), "signals": signals, "strokes": strokes}
with open(os.path.join(out, "session.json"), "w") as handle:
    json.dump(fixture, handle, indent=2)
with open(os.path.join(out, "timeline.json"), "w") as handle:
    json.dump({"sentences": [{"text": s, "start": a, "end": b} for s, (a, b) in zip(sentences, starts)], "total": total, "pins": [pin1, pin2], "stroke": [stroke_start, stroke_end]}, handle, indent=2)
print(json.dumps({"total": total, "starts": starts}))
