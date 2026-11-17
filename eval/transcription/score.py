#!/usr/bin/env python3
import json, re, sys, os, glob, argparse

TAG = re.compile(r"\[([^\]]+)\]")

NUMBERS = {"zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
           "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14",
           "fifteen": "15", "sixteen": "16", "seventeen": "17", "eighteen": "18", "nineteen": "19", "twenty": "20",
           "thirty": "30", "forty": "40", "fifty": "50", "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90",
           "hundred": "100", "thousand": "1000"}
SPELLINGS = {"ok": "okay", "colour": "color", "grey": "gray", "e-mail": "email", "%": "percent"}

CAMEL = re.compile(r"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])")

def normalize(text):
    text = CAMEL.sub(" ", text)
    text = text.lower().replace("’", "'").replace("‘", "'").replace("…", " ")
    text = re.sub(r"[-–—/]", " ", text)
    text = re.sub(r"[^\w\s'%]", " ", text)
    text = text.replace("'", "")
    words = []
    for w in text.split():
        w = SPELLINGS.get(w, w)
        w = NUMBERS.get(w, w)
        words.append(w)
    return words

def parse_reference(text):
    tokens, terms = [], []
    pos = 0
    for m in TAG.finditer(text):
        tokens.extend(normalize(text[pos:m.start()]))
        term_tokens = normalize(m.group(1))
        terms.append((m.group(1), len(tokens), len(tokens) + len(term_tokens)))
        tokens.extend(term_tokens)
        pos = m.end()
    tokens.extend(normalize(text[pos:]))
    return tokens, terms

def align(ref, hyp):
    n, m = len(ref), len(hyp)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(1, n + 1): d[i][0] = i
    for j in range(1, m + 1): d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            cost = 0 if ref[i - 1] == hyp[j - 1] else 1
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
    ops = []
    i, j = n, m
    while i > 0 or j > 0:
        if i > 0 and j > 0 and d[i][j] == d[i - 1][j - 1] + (0 if ref[i - 1] == hyp[j - 1] else 1):
            ops.append(("match" if ref[i - 1] == hyp[j - 1] else "sub", i - 1, j - 1)); i -= 1; j -= 1
        elif i > 0 and d[i][j] == d[i - 1][j] + 1:
            ops.append(("del", i - 1, None)); i -= 1
        else:
            ops.append(("ins", None, j - 1)); j -= 1
    ops.reverse()
    return ops

def score(reference_text, hypothesis_text):
    ref, terms = parse_reference(reference_text)
    hyp = normalize(hypothesis_text)
    ops = align(ref, hyp)
    counts = {"sub": 0, "del": 0, "ins": 0, "match": 0}
    ref_status = {}
    for op, i, j in ops:
        counts[op] += 1
        if i is not None: ref_status[i] = op
    errors = counts["sub"] + counts["del"] + counts["ins"]
    term_results = []
    for name, start, end in terms:
        ok = all(ref_status.get(k) == "match" for k in range(start, end))
        exact = re.search(r"(?<!\w)" + re.escape(name.lower()) + r"(?!\w)", hypothesis_text.lower()) is not None
        term_results.append({"term": name, "correct": ok, "exact": exact})
    wrong = sum(1 for t in term_results if not t["correct"])
    not_exact = sum(1 for t in term_results if not t["exact"])
    return {
        "ref_words": len(ref), "hyp_words": len(hyp),
        "sub": counts["sub"], "del": counts["del"], "ins": counts["ins"], "errors": errors,
        "wer": errors / len(ref) if ref else None,
        "terms": len(terms), "terms_wrong": wrong, "terms_not_exact": not_exact,
        "term_error_rate": wrong / len(terms) if terms else None,
        "term_exact_error_rate": not_exact / len(terms) if terms else None,
        "term_results": term_results,
    }

def hypothesis_text(path):
    with open(path) as f:
        data = json.load(f)
    return data.get("text") or " ".join(s["text"] for s in data.get("segments", []))

def main():
    p = argparse.ArgumentParser(description="WER and tagged-term error for transcription outputs")
    p.add_argument("--refs", required=True, help="directory of <name>.txt references with [tagged] terms")
    p.add_argument("--hyps", required=True, help="directory of <name>.<variant>.json harness outputs")
    p.add_argument("--variants", default="a,b,c,d")
    p.add_argument("--details", action="store_true", help="print per-term results (private data: never paste into a proof)")
    p.add_argument("--json", help="write the full score table here")
    args = p.parse_args()
    variants = args.variants.split(",")
    rows, totals = [], {v: {"ref_words": 0, "errors": 0, "terms": 0, "terms_wrong": 0, "terms_not_exact": 0, "files": 0} for v in variants}
    for ref_path in sorted(glob.glob(os.path.join(args.refs, "*.txt"))):
        name = os.path.splitext(os.path.basename(ref_path))[0]
        with open(ref_path) as f:
            reference = f.read()
        for v in variants:
            hyp_path = os.path.join(args.hyps, f"{name}.{v}.json")
            if not os.path.exists(hyp_path):
                continue
            s = score(reference, hypothesis_text(hyp_path))
            s.update({"name": name, "variant": v})
            rows.append(s)
            t = totals[v]
            t["ref_words"] += s["ref_words"]; t["errors"] += s["errors"]
            t["terms"] += s["terms"]; t["terms_wrong"] += s["terms_wrong"]; t["terms_not_exact"] += s["terms_not_exact"]; t["files"] += 1
    print("| case | variant | ref words | S | D | I | WER | terms | term errors (spoken) | term errors (written form) |")
    print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for s in rows:
        print(f"| {s['name']} | {s['variant']} | {s['ref_words']} | {s['sub']} | {s['del']} | {s['ins']} | {s['wer']:.1%} | {s['terms']} | {s['terms_wrong']} | {s['terms_not_exact']} |")
    print()
    print("| variant | files | ref words | WER | terms | term error rate (spoken form) | term error rate (written form) |")
    print("|---|---:|---:|---:|---:|---:|---:|")
    for v, t in totals.items():
        if t["files"] == 0: continue
        wer = t["errors"] / t["ref_words"] if t["ref_words"] else 0
        ter = t["terms_wrong"] / t["terms"] if t["terms"] else 0
        tex = t["terms_not_exact"] / t["terms"] if t["terms"] else 0
        print(f"| {v} | {t['files']} | {t['ref_words']} | {wer:.1%} | {t['terms']} | {ter:.0%} | {tex:.0%} |")
    if args.details:
        for s in rows:
            missed = [t["term"] for t in s["term_results"] if not t["correct"]]
            misspelled = [t["term"] for t in s["term_results"] if t["correct"] and not t["exact"]]
            print(f"{s['name']} {s['variant']} missed terms: {missed}; right words, written differently: {misspelled}")
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"rows": rows, "totals": totals}, f, indent=2)

if __name__ == "__main__":
    main()
