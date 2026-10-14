"""#203 general corpus pilot: blind founder rating before the full 200/language run.

E / K / C = pilot en / sk / cs on the subscription (narrow themes, taste brief).
A = anchor: unrated taste-brief questions (T en + S sk) from taste-2026-10-14,
generated on the direct API, so drift between rounds stays visible.
Fixed seed, shuffled; the key stays in blind_key.json.
"""

import json
import random
from pathlib import Path

RUN = Path(__file__).parent
TASTE = RUN.parent / "taste-2026-10-14"
QUOTA = {"E": 8, "K": 8, "C": 8, "A": 6}


def load(run, arm):
    return [q for p in sorted(run.glob(f"{arm}-[0-9].json")) for q in json.loads(p.read_text())]


def options(q):
    pa = q.get("possible_answers") or {}
    return [str(v) for _, v in sorted(pa.items())] if isinstance(pa, dict) else []


rated = {v["qid"] for v in json.loads((TASTE / "blind_key.json").read_text()).values()}
pools = {a: load(RUN, a) for a in "EKC"}
pools["A"] = [q for a in "TS" for q in load(TASTE, a) if q["id"] not in rated]
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
