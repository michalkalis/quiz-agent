"""#211 211.4: blind original-vs-rewrite pairs from the naturalness backfill.

Usage: python build_pairs.py <verdicts.json from check_naturalness.py --out>
Writes pairs.html (rating page) and pairs_key.json (which side is the rewrite)
next to this script. 10 flagged rows per language, spread over problem kinds.
"""

import difflib
import json
import os
import random
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PER_LANGUAGE = 10
rng = random.Random(2114)


def segments(a: str, b: str):
    """Word-level diff: each side as [(text, changed)] runs."""
    ta, tb = re.findall(r"\S+|\s+", a), re.findall(r"\S+|\s+", b)
    sa, sb = [], []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, ta, tb, autojunk=False).get_opcodes():
        sa.append(("".join(ta[i1:i2]), op != "equal"))
        sb.append(("".join(tb[j1:j2]), op != "equal"))
    return [s for s in sa if s[0]], [s for s in sb if s[0]]


def pick(rows):
    """Round-robin over the first problem kind so every kind is represented."""
    by_kind = {}
    for r in rows:
        by_kind.setdefault(r["verdict"]["problems"][0]["kind"], []).append(r)
    for v in by_kind.values():
        rng.shuffle(v)
    out = []
    while len(out) < PER_LANGUAGE and any(by_kind.values()):
        for k in sorted(by_kind):
            if by_kind[k] and len(out) < PER_LANGUAGE:
                out.append(by_kind[k].pop())
    return out


rows = json.load(open(sys.argv[1]))
flagged = [r for r in rows if r["verdict"] and not r["verdict"]["ok"]
           and r["verdict"].get("rewrite") and r["verdict"]["rewrite"] != r["question"]]
chosen = []
for lang in ("sk", "cs"):
    chosen += pick([r for r in flagged if r["language"] == lang])
rng.shuffle(chosen)

items, key = [], {}
for n, r in enumerate(chosen, 1):
    pid = f"P{n}"
    orig, new = segments(r["question"], r["verdict"]["rewrite"])
    rewrite_first = rng.random() < 0.5
    v1, v2 = (new, orig) if rewrite_first else (orig, new)
    items.append({"id": pid, "lang": r["language"], "answer": r["answer"], "v1": v1, "v2": v2})
    key[pid] = {"qid": r["id"], "rewrite_side": "1" if rewrite_first else "2",
                "kinds": [p["kind"] for p in r["verdict"]["problems"]]}

tpl = open(os.path.join(HERE, "pairs_template.html")).read()
open(os.path.join(HERE, "pairs.html"), "w").write(
    tpl.replace("__ITEMS__", json.dumps(items, ensure_ascii=False).replace("</", "<\\/")))
json.dump(key, open(os.path.join(HERE, "pairs_key.json"), "w"), indent=1)
print(f"{len(items)} pairs; flagged with rewrite: {len(flagged)}")
