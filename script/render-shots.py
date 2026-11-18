#!/usr/bin/env python3
import argparse
import glob
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zlib

SHOTS = [
    ("recording-bar", "design", "bar-standard-{scheme}-*-transcript-3.png"),
    ("review-tasks", "review", "review-three-{scheme}-standard.png"),
    ("review-walkthrough", "review", "review-walkthrough-{scheme}-standard.png"),
    ("transcriber-choice", "engine", "onboarding-1-offer-{scheme}-standard.png"),
    ("transcriber-download", "engine", "onboarding-2-downloading-{scheme}-standard.png"),
    ("menu-bar-panel", "panel", "panel-content-{scheme}-standard.png"),
]

NARRATION = "The pay button is too small. [[slnc 2500]] Next thing, the footer overlaps. [[slnc 2500]] Also the settings sidebar should remember which section was open."


def run(cmd, **kw):
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True, **kw)


def build(root, derived):
    run(["xcodegen", "generate", "--quiet"], cwd=os.path.join(root, "mac"))
    run(["xcodebuild", "-project", "Scout.xcodeproj", "-scheme", "Scout", "-configuration", "Debug",
         "-derivedDataPath", derived, "-destination", "platform=macOS,arch=arm64", "-quiet", "build"],
        cwd=os.path.join(root, "mac"))
    return os.path.join(derived, "Build/Products/Debug/Scout.app")


def wait_for(path, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if glob.glob(path):
            return
        time.sleep(2)
    sys.exit(f"timed out waiting for {path}")


def render(app, work):
    binary = os.path.join(app, "Contents/MacOS/Scout")
    for kind in ("panel", "review", "engine"):
        run([binary, f"--{kind}-gallery={os.path.join(work, kind)}"], timeout=600)
    narration = os.path.join(work, "narration.aiff")
    run(["say", "-o", narration, NARRATION])
    run(["open", "-g", "-n", "-W", app, "--args", f"--simulate-session={narration}", "--dry-run-delivery",
         "--simulate-review", f"--data-root={os.path.join(work, 'data')}", f"--simulate-output={os.path.join(work, 'sim')}",
         f"--design-gallery={os.path.join(work, 'design')}"], timeout=900)
    wait_for(os.path.join(work, "design", "bar-frames.json"), 60)


def chunks(data):
    pos = 8
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        yield kind, data[pos + 8:pos + 8 + length]
        pos += 12 + length


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def decode(data):
    idat = b""
    for kind, body in chunks(data):
        if kind == b"IHDR":
            width, height, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
    if depth not in (8, 16) or interlace or ctype not in (2, 6):
        return None
    bpp = (4 if ctype == 6 else 3) * depth // 8
    stride = width * bpp
    raw = zlib.decompress(idat)
    rows, prev = [], bytearray(stride)
    for y in range(height):
        f = raw[y * (stride + 1)]
        row = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        if f == 1:
            for i in range(bpp, stride):
                row[i] = (row[i] + row[i - bpp]) & 255
        elif f == 2:
            row = bytearray((r + p) & 255 for r, p in zip(row, prev))
        elif f == 3:
            for i in range(stride):
                row[i] = (row[i] + ((row[i - bpp] if i >= bpp else 0) + prev[i]) // 2) & 255
        elif f == 4:
            for i in range(stride):
                a = row[i - bpp] if i >= bpp else 0
                c = prev[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + paeth(a, prev[i], c)) & 255
        rows.append(bytes(row))
        prev = row
    return width, height, depth, ctype, bpp, rows


def filtered(row, prev, bpp, f):
    if f == 0:
        return row
    if f == 1:
        return bytes((row[i] - (row[i - bpp] if i >= bpp else 0)) & 255 for i in range(len(row)))
    if f == 2:
        return bytes((r - p) & 255 for r, p in zip(row, prev))
    return bytes((row[i] - paeth(row[i - bpp] if i >= bpp else 0, prev[i], prev[i - bpp] if i >= bpp else 0)) & 255
                 for i in range(len(row)))


def encode(width, height, depth, ctype, bpp, rows, strategy, color):
    out, prev = bytearray(), bytes(len(rows[0]))
    for row in rows:
        if strategy == "adaptive":
            f, best = min(((g, filtered(row, prev, bpp, g)) for g in (0, 1, 2, 4)),
                          key=lambda c: sum(b if b < 128 else 256 - b for b in c[1]))
            out += bytes([f]) + best
        else:
            out += bytes([strategy]) + filtered(row, prev, bpp, strategy)
        prev = row
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
    ihdr = struct.pack(">IIBBBBB", width, height, depth, ctype, 0, 0, 0)
    extra = b"".join(chunk(kind, body) for kind, body in color)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + extra + chunk(b"IDAT", zlib.compress(bytes(out), 9)) + chunk(b"IEND", b"")


def optimise(path):
    data = open(path, "rb").read()
    image = decode(data)
    if image is None:
        return len(data), len(data)
    width, height, depth, ctype, bpp, rows = image
    color = [(k, b) for k, b in chunks(data) if k in (b"iCCP", b"cICP", b"sRGB", b"gAMA", b"cHRM", b"pHYs")]
    if depth == 16 and all(row[0::2] == row[1::2] for row in rows):
        rows = [row[0::2] for row in rows]
        depth, bpp = 8, bpp // 2
    if depth == 8 and ctype == 6 and all(row[3::4] == b"\xff" * width for row in rows):
        rows = [bytes(b for i, b in enumerate(row) if i % 4 != 3) for row in rows]
        ctype, bpp = 2, 3
    best = data
    for strategy in (0, 1, 2, 4, "adaptive"):
        candidate = encode(width, height, depth, ctype, bpp, rows, strategy, color)
        if len(candidate) < len(best):
            best = candidate
    if best is not data and decode(best)[5] != rows:
        sys.exit(f"lossless check failed for {path}")
    open(path, "wb").write(best)
    return len(data), len(best)


def collect(source, out):
    os.makedirs(out, exist_ok=True)
    for name, kind, pattern in SHOTS:
        for scheme in ("dark", "light"):
            matches = sorted(glob.glob(os.path.join(source, kind, pattern.format(scheme=scheme))))
            if not matches:
                print(f"missing {kind}/{pattern.format(scheme=scheme)}")
                continue
            target = os.path.join(out, f"{name}-{scheme}@2x.png")
            shutil.copyfile(matches[-1], target)
            before, after = optimise(target)
            print(f"{os.path.basename(target)}  {os.path.relpath(matches[-1], source)}  {before} -> {after} bytes")


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    parser = argparse.ArgumentParser()
    parser.add_argument("--from", dest="source", help="use existing gallery output instead of building and rendering")
    parser.add_argument("--app", help="use this Scout.app instead of building one")
    parser.add_argument("--out", default=os.path.join(root, "site/assets/shots"))
    args = parser.parse_args()
    source = args.source
    if not source:
        if sys.platform != "darwin":
            sys.exit("rendering needs macOS; pass --from <dir> to only collect and optimise")
        source = tempfile.mkdtemp(prefix="scout-shots-")
        app = args.app or build(root, os.path.join(root, "build/ShotsDerivedData"))
        render(app, source)
    collect(source, args.out)


if __name__ == "__main__":
    main()
