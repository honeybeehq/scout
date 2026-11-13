#!/usr/bin/env python3
import json, sys, re

def norm(s):
    s = s.lower().replace("…", " ").replace("’", "'")
    s = re.sub(r"[^\w\s']", " ", s)
    return " ".join(s.split())

def main(path):
    with open(path) as f:
        w = json.load(f)
    transcript = norm(" ".join(s.get("text", "") for s in w.get("transcript", {}).get("segments", [])))
    labels = []
    for p in w.get("pointers", []):
        if p.get("label"): labels.append((p["id"], p["label"]))
    checked = []
    for pid, label in labels:
        phrase = norm(label)
        words = phrase.split()
        full = phrase in transcript
        partial = sum(1 for x in words if re.search(rf"\b{re.escape(x)}\b", transcript)) / len(words) if words else 0
        checked.append({"pointer": pid, "words": len(words), "full_match": full, "word_coverage": round(partial, 2)})
    print(json.dumps({
        "walkthrough": w.get("id"),
        "transcript_engine": w.get("transcript", {}).get("engine"),
        "transcript_language": w.get("transcript", {}).get("language"),
        "has_audio": (w.get("clip") or {}).get("hasAudio"),
        "transcript_words": len(transcript.split()),
        "pointer_labels": len(labels),
        "full_matches": sum(1 for c in checked if c["full_match"]),
        "mean_word_coverage": round(sum(c["word_coverage"] for c in checked) / len(checked), 2) if checked else None,
        "pointers": checked,
    }, indent=2))

if __name__ == "__main__":
    main(sys.argv[1])
