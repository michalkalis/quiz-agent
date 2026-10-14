"""#203 variety pilot: blind founder rating, variety recipe vs the general pilot recipe.

V / W / Y = variety brief en / sk / cs (fun-sourced themes, mixed shapes).
E / K / C = control: unrated questions from general-pilot-2026-10-14 (taste brief,
narrow everyday themes), same round so the founder's scale drift cancels out.
Fixed seed, shuffled; the key stays in blind_key.json.
"""

import json
import random
from pathlib import Path

RUN = Path(__file__).parent
PILOT = RUN.parent / "general-pilot-2026-10-14"
QUOTA = {"V": 7, "W": 7, "Y": 7, "E": 3, "K": 3, "C": 3}


def load(run, arm):
    return [q for p in sorted(run.glob(f"{arm}-[0-9].json")) for q in json.loads(p.read_text())]


def options(q):
    pa = q.get("possible_answers") or {}
    return [str(v) for _, v in sorted(pa.items())] if isinstance(pa, dict) else []


rated = {v["qid"] for v in json.loads((PILOT / "blind_key.json").read_text()).values()}
pools = {a: load(RUN, a) for a in "VWY"}
pools.update({a: [q for q in load(PILOT, a) if q["id"] not in rated] for a in "EKC"})
rng = random.Random(2036)
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
