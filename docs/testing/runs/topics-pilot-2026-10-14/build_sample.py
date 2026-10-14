"""#203.8 topics pilot: blind founder rating, model-brainstormed themes vs hand-written themes.

M / N / O = model themes en / sk / cs; H / J / L = hand themes en / sk / cs (from the
45 full-run themes). Both arms: taste brief, 2 questions per theme, same pins, same
round, so the founder's scale drift cancels out. 10 + 10 per language.
Fixed seed, shuffled; the key stays in blind_key.json.
"""

import json
import random
from pathlib import Path

RUN = Path(__file__).parent
QUOTA = {a: 10 for a in "MNOHJL"}


def load(run, arm):
    paths = [p for p in run.glob(f"{arm}-*.json") if p.stem.split("-")[1].isdigit()]
    return [q for p in sorted(paths) for q in json.loads(p.read_text())]


def options(q):
    pa = q.get("possible_answers") or {}
    return [str(v) for _, v in sorted(pa.items())] if isinstance(pa, dict) else []


pools = {a: load(RUN, a) for a in QUOTA}
rng = random.Random(2039)
picks = []
for arm, n in QUOTA.items():
    print(arm, len(pools[arm]))
    picks += [(arm, q) for q in rng.sample(pools[arm], min(n, len(pools[arm])))]
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
