#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import tempfile

WIDTH, HEIGHT, FPS = 1600, 900, 30


def run(cmd, **kw):
    print("+", " ".join(cmd), flush=True)
    return subprocess.run(cmd, check=True, **kw)


def probe(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height:format=duration",
                          "-of", "json", path], check=True, capture_output=True, text=True).stdout
    data = json.loads(out)
    return data["streams"][0]["width"], data["streams"][0]["height"], float(data["format"]["duration"])


def gray_frames(path, crop, start, seconds, size=(64, 36)):
    w, h = size
    cmd = ["ffmpeg", "-v", "error", "-ss", str(start), "-t", str(seconds), "-i", path,
           "-vf", f"crop={crop},scale={w}:{h},format=gray,fps={FPS}", "-f", "rawvideo", "-"]
    raw = subprocess.run(cmd, check=True, capture_output=True).stdout
    step = w * h
    return [raw[i:i + step] for i in range(0, len(raw) - step + 1, step)]


def first_change(path, crop, start, seconds, threshold):
    frames = gray_frames(path, crop, start, seconds)
    base = frames[0]
    for index, frame in enumerate(frames):
        diff = sum(abs(a - b) for a, b in zip(frame, base)) / len(frame)
        if diff > threshold:
            return start + index / FPS
    sys.exit(f"no change found in {path} ({crop})")


def ass_time(seconds):
    seconds = max(0, seconds)
    h = int(seconds // 3600)
    m = int(seconds % 3600 // 60)
    s = seconds % 60
    return f"{h}:{m:02d}:{s:05.2f}"


def write_ass(path, captions, font):
    lines = [
        "[Script Info]", "ScriptType: v4.00+", f"PlayResX: {WIDTH}", f"PlayResY: {HEIGHT}", "WrapStyle: 0", "",
        "[V4+ Styles]",
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, "
        "ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding",
        f"Style: Caption,{font},34,&H00FFFFFF,&H00FFFFFF,&H30111111,&H30111111,-1,0,0,0,100,100,0,0,3,14,0,2,80,80,46,1",
        f"Style: Quote,{font},34,&H00FFFFFF,&H00FFFFFF,&H30111111,&H30111111,0,-1,0,0,100,100,0,0,3,14,0,2,80,80,46,1",
        "", "[Events]", "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
    ]
    for start, end, style, text in captions:
        lines.append(f"Dialogue: 0,{ass_time(start)},{ass_time(end)},{style},,0,0,0,,{{\\fad(120,120)}}{text}")
    open(path, "w").write("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("run", help="the out directory of script/record-hero.sh")
    parser.add_argument("--out", default=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "site/assets/hero"))
    parser.add_argument("--font", default="Liberation Sans")
    parser.add_argument("--fontsdir", default="/usr/share/fonts/truetype/liberation")
    parser.add_argument("--crf", default="30")
    parser.add_argument("--webm-crf", default="44")
    parser.add_argument("--draft", action="store_true", help="only write hero-draft.mp4")
    args = parser.parse_args()

    report = json.load(open(os.path.join(args.run, "hero-report.json")))
    events = {}
    for event in report["events"]:
        events.setdefault(event["name"], []).append(event["at"])
    t = {name: times[0] for name, times in events.items()}
    lines = open(os.path.join(args.run, "speech.txt")).read().splitlines()
    lead, first, gap, second = (float(x) for x in lines[2].split(","))

    part_a = os.path.join(args.run, "part-a.mov")
    part_b = os.path.join(args.run, "part-b.mov")
    aw, ah, _ = probe(part_a)
    scale = aw / 1920
    bar = f"{int(560 * scale)}:{int(60 * scale)}:{int(680 * scale)}:0"
    guess = t["session.start"] - t["partA.launched"]
    bar_seen = first_change(part_a, bar, max(0, guess - 3), 8, 6)
    offset_a = bar_seen - 0.12 - t["session.start"]
    centre = f"{int(800 * scale)}:{int(500 * scale)}:{int(560 * scale)}:{int(290 * scale)}"
    guess_b = t["safari.front"] - t["partB.launched"]
    raised = first_change(part_b, centre, max(0, guess_b - 3), 8, 10)
    offset_b = raised - 0.05 - t["safari.front"]
    print(f"part A offset {offset_a:.3f}, part B offset {offset_b:.3f}")

    def a(name, delta=0.0):
        return t[name] + offset_a + delta

    def b(name, delta=0.0):
        return t[name] + offset_b + delta

    s1 = (a("session.start", -0.7), a("session.finish", 0.5), 1.0)
    s2 = (a("review.shown", -0.1), a("copy.done", 1.8), 1.3)
    s3 = (b("safari.front", -1.2), b("patch.applied", 3.6), 1.0)
    segments = [(part_a,) + s1, (part_a,) + s2, (part_b,) + s3]
    fade = 0.25
    lengths = [(end - start) / speed for _, start, end, speed in segments]
    starts = [0.0]
    for length in lengths[:-1]:
        starts.append(starts[-1] + length - fade)
    total = starts[-1] + lengths[-1]

    session0 = starts[0] + 0.7
    speech1 = session0 + lead
    speech2 = session0 + lead + first + gap
    review0 = starts[1] + 0.1 / s2[2]
    copy0 = starts[1] + (a("copy.click") - s2[0]) / s2[2]
    reload0 = starts[2] + (b("patch.applied") - s3[0])
    line1, line2 = lines[0], lines[1]
    captions = [
        (0.1, speech1 - 0.1, "Caption", "Scout is recording the screen and your voice"),
        (speech1, speech1 + first + 0.3, "Quote", f"“{line1}”"),
        (speech1 + first + 0.5, speech2 - 0.1, "Caption", "Pin a second element"),
        (speech2, speech2 + second + 0.3, "Quote", f"“{line2}”"),
        (starts[1] + 0.2, copy0 - 0.2, "Caption", "Stop. Each ask became its own task"),
        (copy0, starts[2] - 0.1, "Caption", "Copy all: both tasks go to a coding agent"),
        (starts[2] + 0.3, reload0 - 0.1, "Caption", "The agent edited the page"),
        (reload0, total - 0.1, "Caption", "The page reloads with both changes"),
    ]

    work = tempfile.mkdtemp(prefix="scout-hero-render-")
    ass = os.path.join(work, "captions.ass")
    write_ass(ass, captions, args.font)

    inputs, filters = [], []
    for index, (path, start, end, speed) in enumerate(segments):
        inputs += ["-ss", f"{start:.3f}", "-t", f"{end - start:.3f}", "-i", path]
        filters.append(f"[{index}:v]setpts=(PTS-STARTPTS)/{speed},fps={FPS},scale={WIDTH}:{HEIGHT}:flags=lanczos,format=yuv420p,settb=1/{FPS}[v{index}]")
    chain = "v0"
    for index in range(1, len(segments)):
        filters.append(f"[{chain}][v{index}]xfade=transition=fade:duration={fade}:offset={starts[index]:.3f}[x{index}]")
        chain = f"x{index}"
    filters.append(f"[{chain}]subtitles={ass}:fontsdir={args.fontsdir}[vout]")
    narration = os.path.join(args.run, "narration.aiff")
    audio_index = len(segments)
    inputs += ["-i", narration]
    delay = int(session0 * 1000)
    filters.append(f"[{audio_index}:a]atrim=0:{s1[1] - s1[0] - 0.7:.3f},afade=t=out:st={max(0, s1[1] - s1[0] - 1.2):.3f}:d=0.5,"
                   f"adelay={delay}|{delay},apad,atrim=0:{total:.3f},aformat=channel_layouts=mono:sample_rates=48000[aout]")
    graph = ";".join(filters)
    os.makedirs(args.out, exist_ok=True)

    if args.draft:
        run(["ffmpeg", "-v", "error", "-y", *inputs, "-filter_complex", graph, "-map", "[vout]", "-map", "[aout]",
             "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-c:a", "aac", "-b:a", "96k", os.path.join(work, "hero-draft.mp4")])
        print(os.path.join(work, "hero-draft.mp4"))
        return

    master = os.path.join(work, "master.mkv")
    run(["ffmpeg", "-v", "error", "-y", *inputs, "-filter_complex", graph, "-map", "[vout]", "-map", "[aout]",
         "-c:v", "libx264", "-preset", "slow", "-crf", "12", "-c:a", "pcm_s16le", master])
    mp4 = os.path.join(args.out, "hero.mp4")
    run(["ffmpeg", "-v", "error", "-y", "-i", master, "-c:v", "libx264", "-preset", "veryslow", "-crf", args.crf, "-tune", "stillimage",
         "-profile:v", "high", "-pix_fmt", "yuv420p", "-g", str(FPS * 4), "-c:a", "aac", "-b:a", "48k", "-movflags", "+faststart", mp4])
    webm = os.path.join(args.out, "hero.webm")
    run(["ffmpeg", "-v", "error", "-y", "-i", master, "-c:v", "libvpx-vp9", "-b:v", "0", "-crf", args.webm_crf, "-row-mt", "1",
         "-deadline", "good", "-cpu-used", "1", "-g", str(FPS * 4), "-pass", "1", "-an", "-f", "null", "-passlogfile", os.path.join(work, "vp9"), "/dev/null"])
    run(["ffmpeg", "-v", "error", "-y", "-i", master, "-c:v", "libvpx-vp9", "-b:v", "0", "-crf", args.webm_crf, "-row-mt", "1",
         "-deadline", "good", "-cpu-used", "1", "-g", str(FPS * 4), "-pass", "2", "-passlogfile", os.path.join(work, "vp9"),
         "-c:a", "libopus", "-b:a", "32k", webm])
    poster_at = (a("pin.button", 0.25) - s1[0])
    poster_png = os.path.join(work, "poster.png")
    run(["ffmpeg", "-v", "error", "-y", "-ss", f"{poster_at:.3f}", "-i", master, "-frames:v", "1", poster_png])
    run(["ffmpeg", "-v", "error", "-y", "-i", poster_png, "-c:v", "libwebp", "-quality", "82", os.path.join(args.out, "hero-poster.webp")])
    run(["ffmpeg", "-v", "error", "-y", "-i", poster_png, "-q:v", "4", os.path.join(args.out, "hero-poster.jpg")])
    json.dump({"offsets": [offset_a, offset_b], "segments": [list(s[1:]) for s in segments], "captions": captions, "total": total,
               "poster": poster_at}, open(os.path.join(work, "edit.json"), "w"), indent=2, ensure_ascii=False)
    for name in ("hero.mp4", "hero.webm", "hero-poster.webp", "hero-poster.jpg"):
        print(f"{name}  {os.path.getsize(os.path.join(args.out, name))} bytes")
    print(f"work: {work}")


if __name__ == "__main__":
    main()
