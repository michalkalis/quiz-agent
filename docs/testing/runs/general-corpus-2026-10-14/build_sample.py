"""#203 full run gate: blind founder sample of 20 per language (founder 2026-10-14: every bulk batch,
import only at ⌀ ≥ 7). Draws from the new full-run questions only (the pilot ones were rated already),
after same-fact duplicates were removed. Arms: E/F en, S/T sk, C/D cs (H / M themes).
Usage: build_sample.py [drop-file]   drop-file = lines "<arm>-<n>#<i>" removed by the duplicate review.
"""

import json
import random
import sys
from pathlib import Path

RUN = Path(__file__).parent
LANGS = {"en": "EF", "sk": "ST", "cs": "CD"}
drops = set(Path(sys.argv[1]).read_text().split()) if len(sys.argv) > 1 else set()


def load(arm):
    out = []
    for p in sorted(RUN.glob(f"{arm}-*.json")):
        if not p.stem.split("-")[1].isdigit():
            continue
        out += [q for i, q in enumerate(json.loads(p.read_text()), 1) if f"{p.stem}#{i}" not in drops]
    return out


def options(q):
    pa = q.get("possible_answers") or {}
    return [str(v) for _, v in sorted(pa.items())] if isinstance(pa, dict) else []


rng = random.Random(2041)
picks = []
for lang, arms in LANGS.items():
    pool = [(a, q) for a in arms for q in load(a)]
    print(lang, len(pool))
    picks += rng.sample(pool, min(20, len(pool)))
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
