#!/usr/bin/env python3
import json, glob, os, sys, statistics, argparse

def load(dir_):
    runs = {}
    for p in sorted(glob.glob(os.path.join(dir_, "*.run*.json"))):
        name = os.path.basename(p)[:-5]
        case, variant, run = name.rsplit(".", 2)
        with open(p) as f:
            runs.setdefault((case, variant), []).append((run, json.load(f)["metrics"]))
    return runs

def fmt(x, digits=2):
    return "-" if x is None else f"{x:.{digits}f}"

def main():
    ap = argparse.ArgumentParser(description="speed and memory table from harness outputs")
    ap.add_argument("dirs", nargs="+", help="output directories, optionally label=dir")
    args = ap.parse_args()
    print("| machine | case | variant | engine | runs | load s (first / later) | analysis s | RTF | finalize lag s | harness peak MB | speech daemon peak MB |")
    print("|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|")
    for spec in args.dirs:
        label, _, dir_ = spec.rpartition("=")
        for (case, variant), items in sorted(load(dir_).items()):
            ms = [m for _, m in sorted(items)]
            first = ms[0]
            later = ms[1:] or ms
            med = lambda key: statistics.median(m[key] for m in later if m.get(key) is not None) if any(m.get(key) is not None for m in later) else None
            machine = label or f"{first['chip']}"
            engine = first["engine"] + ("/" + first["preset"] if first["engine"] == "apple" else "")
            for m in ms:
                if "speechDaemonPeakMB" not in m and "engineProcessPeakMB" in m:
                    m["speechDaemonPeakMB"] = m["engineProcessPeakMB"]
            daemon = med("speechDaemonPeakMB") if first["engine"] == "apple" else None
            print(f"| {machine} | {case} | {variant} | {engine} | {len(ms)} | {fmt(first['loadSeconds'])} / {fmt(med('loadSeconds'))} | {fmt(med('analysisSeconds'))} | {fmt(med('realTimeFactor'), 3)} | {fmt(med('finalizeLagSeconds'))} | {fmt(med('peakFootprintMB'), 0)} | {fmt(daemon, 0)} |")
    print()
    for spec in args.dirs:
        label, _, dir_ = spec.rpartition("=")
        for (case, variant), items in sorted(load(dir_).items()):
            m = items[0][1]
            print(f"{label or m['chip']}: {m['machine']} {m['chip']} {m['osVersion']}")
            break

if __name__ == "__main__":
    main()
