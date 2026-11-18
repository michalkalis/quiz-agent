"""#211 211.4 round 2: blind pairs for the smallest-edit rewrites (prompt v2).

Usage: python build_pairs_round2.py verdicts_v1.json verdicts_v2.json
16 pairs (8 sk + 8 cs) from rows v2 still flags, plus 4 (2 + 2) from rows v1
flagged but v2 now calls fine, shown with the v1 rewrite: they test whether
the stricter prompt drops real problems. Writes pairs_round2.html and
pairs_round2_key.json next to this script.
"""

import difflib
import json
import os
import random
import re
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
rng = random.Random(21142)


def segments(a, b):
    ta, tb = re.findall(r"\S+|\s+", a), re.findall(r"\S+|\s+", b)
    sa, sb = [], []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, ta, tb, autojunk=False).get_opcodes():
        sa.append(("".join(ta[i1:i2]), op != "equal"))
        sb.append(("".join(tb[j1:j2]), op != "equal"))
    return [s for s in sa if s[0]], [s for s in sb if s[0]]


def latin(t):
    return all(not c.isalpha() or unicodedata.name(c, "").startswith("LATIN") for c in t)


v1 = {x["id"]: x for x in json.load(open(sys.argv[1]))}
v2 = json.load(open(sys.argv[2]))
chosen = []
for lang in ("sk", "cs"):
    flagged = [x for x in v2 if x["language"] == lang and not x["verdict"]["ok"]
               and latin(x["verdict"]["rewrite"])]
    dropped = [x for x in v2 if x["language"] == lang and x["verdict"]["ok"]]
    rng.shuffle(flagged)
    rng.shuffle(dropped)
    chosen += [("v2", x, x["verdict"]["rewrite"]) for x in flagged[:8]]
    chosen += [("v1-dropped", x, v1[x["id"]]["verdict"]["rewrite"]) for x in dropped[:2]]
rng.shuffle(chosen)

items, key = [], {}
for n, (arm, r, rewrite) in enumerate(chosen, 1):
    pid = f"S{n}"
    orig, new = segments(r["question"], rewrite)
    first = rng.random() < 0.5
    items.append({"id": pid, "lang": r["language"], "answer": r["answer"],
                  "v1": new if first else orig, "v2": orig if first else new})
    key[pid] = {"qid": r["id"], "arm": arm, "rewrite_side": "1" if first else "2", "rewrite": rewrite}

tpl = open(os.path.join(HERE, "pairs_template.html")).read()
tpl = tpl.replace('db.collection("pairs")', 'db.collection("pairs2")')
open(os.path.join(HERE, "pairs_round2.html"), "w").write(
    tpl.replace("__ITEMS__", json.dumps(items, ensure_ascii=False).replace("</", "<\\/")))
json.dump(key, open(os.path.join(HERE, "pairs_round2_key.json"), "w"), indent=1, ensure_ascii=False)
print(len(items), "pairs")
