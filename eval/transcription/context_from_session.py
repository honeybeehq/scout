#!/usr/bin/env python3
import json, sys, re

def strings_from_session(path):
    seen, out = set(), []
    def add(s):
        s = (s or "").strip()
        if len(s) < 2 or s.lower() in seen: return
        seen.add(s.lower()); out.append(s)
    with open(path) as f:
        for line in f:
            try: o = json.loads(line)
            except json.JSONDecodeError: continue
            if o.get("type") == "context":
                app = o["context"].get("app", {})
                add(app.get("name"))
                title = o["context"].get("windowTitle") or ""
                add(title)
                for part in re.split(r"\s[—·|–-]\s", title): add(part)
            target = o.get("target") or (o.get("mark") or {}).get("target") or (o.get("focus") or {}).get("target")
            if isinstance(target, dict):
                add(target.get("label")); add(target.get("role"))
                for a in target.get("ancestry", []) or []:
                    m = re.search(r"“([^”]+)”", a)
                    if m: add(m.group(1))
            if o.get("type") == "visualChange":
                for t in (o.get("visualChange") or o).get("texts", []) or []: add(t)
    return out

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: context_from_session.py signals.jsonl [more.jsonl ...] > context.txt", file=sys.stderr); sys.exit(2)
    seen = set()
    for p in sys.argv[1:]:
        for s in strings_from_session(p):
            if s.lower() not in seen:
                seen.add(s.lower()); print(s)
