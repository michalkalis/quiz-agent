"""#203.5: blind founder rating, old v2_cot prompt (arm A) vs direct_v1 (arm B).

12 per arm from the questions that passed the pipeline gates, fixed seed,
shuffled. The arm key stays in blind_key.json, never in the page.
"""

import json
import random
from pathlib import Path

RUN = Path(__file__).parent
PER_ARM = 12


def load(arm):
    return [q for p in sorted(RUN.glob(f"{arm}-*.json")) for q in json.loads(p.read_text())]


def options(q):
    pa = q.get("possible_answers") or {}
    return [str(v) for _, v in sorted(pa.items())] if isinstance(pa, dict) else []


rng = random.Random(2035)
picks = []
for arm in ("A", "B"):
    pool = load(arm)
    print(arm, len(pool))
    picks += [(arm, q) for q in rng.sample(pool, min(PER_ARM, len(pool)))]
rng.shuffle(picks)
items, key = [], {}
for i, (arm, q) in enumerate(picks, 1):
    rid = f"P{i}"
    answer = q["correct_answer"]
    if q.get("possible_answers") and str(answer) in q["possible_answers"]:
        answer = q["possible_answers"][str(answer)]
    items.append({"id": rid, "lang": "en", "question": q["question"], "answer": str(answer),
                  "options": options(q), "explanation": q.get("explanation") or ""})
    key[rid] = {"arm": arm, "qid": q.get("id"), "topic": q.get("topic")}

page = (RUN / "rating_template.html").read_text().replace(
    "__ITEMS__", json.dumps(items, ensure_ascii=False).replace("</", "<\\/")
)
(RUN / "rating.html").write_text(page)
(RUN / "blind_key.json").write_text(json.dumps(key, ensure_ascii=False, indent=1) + "\n")
print("items", len(items))
