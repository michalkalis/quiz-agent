"""#211 pilot: blind founder sample, current house style (A) vs v2 (B), 10 + 10 per language (sk, cs, en),
same 6 themes in both arms. Usage: build_sample.py → rating.html + blind_key.json.
"""

import json
import random
from pathlib import Path

RUN = Path(__file__).resolve().parent
PER_ARM = 10


def load(arm, lang):
    out = []
    for p in sorted(RUN.glob(f"{arm}-{lang}-*.json")):
        if p.stem.split("-")[2].isdigit():
            out += json.loads(p.read_text())
    return out


def options(q):
    pa = q.get("possible_answers") or {}
    return [str(v) for _, v in sorted(pa.items())] if isinstance(pa, dict) else []


rng = random.Random(211)
picks = []
for lang in ("sk", "cs", "en"):
    for arm in "AB":
        pool = load(arm, lang)
        print(lang, arm, len(pool))
        picks += [(arm, q) for q in rng.sample(pool, min(PER_ARM, len(pool)))]
rng.shuffle(picks)
items, key = [], {}
for i, (arm, q) in enumerate(picks, 1):
    rid = f"R{i}"
    answer = q["correct_answer"]
    if q.get("possible_answers") and str(answer) in q["possible_answers"]:
        answer = q["possible_answers"][str(answer)]
    items.append({"id": rid, "lang": q.get("language") or "en", "question": q["question"],
                  "answer": str(answer), "options": options(q), "explanation": q.get("explanation") or ""})
    key[rid] = {"arm": arm, "qid": q.get("id"), "topic": q.get("topic")}

page = (RUN / "rating_template.html").read_text().replace(
    "__ITEMS__", json.dumps(items, ensure_ascii=False).replace("</", "<\\/")
)
(RUN / "rating.html").write_text(page)
(RUN / "blind_key.json").write_text(json.dumps(key, ensure_ascii=False, indent=1) + "\n")
print("items", len(items))
