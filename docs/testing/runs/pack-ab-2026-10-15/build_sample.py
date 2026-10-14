"""#203 203.9 blind round: old vs new custom packs (3 orders) + optional #202 weekly arm, one page, shuffled.
Per order 3-4 questions per arm (20 pack questions total), weekly 5 + 5 when its JSON exists. Key in blind_key.json.
"""
import json
import random
from pathlib import Path

RUN = Path(__file__).resolve().parent
PER = {"hp": 3, "sport": 4, "food": 3}
rng = random.Random(2039)
picks = []
for slug, n in PER.items():
    for arm in ("old", "new"):
        qs = json.loads((RUN / f"{arm}-{slug}.json").read_text())
        picks += [(f"{arm}-{slug}", q) for q in rng.sample(qs, min(n, len(qs)))]
for arm in ("old", "new"):
    p = RUN / f"weekly-{arm}-en.json"
    if p.exists():
        qs = json.loads(p.read_text())
        picks += [(f"weekly-{arm}", q) for q in rng.sample(qs, min(5, len(qs)))]
rng.shuffle(picks)
items, key = [], {}
for i, (arm, q) in enumerate(picks, 1):
    rid = f"R{i}"
    answer = q["correct_answer"]
    pa = q.get("possible_answers") or {}
    if pa and str(answer) in pa:
        answer = pa[str(answer)]
    opts = [str(v) for _, v in sorted(pa.items())] if isinstance(pa, dict) else []
    items.append({"id": rid, "lang": q.get("language") or "en", "question": q["question"],
                  "answer": str(answer), "options": opts, "explanation": q.get("explanation") or ""})
    key[rid] = {"arm": arm, "qid": q.get("id"), "topic": q.get("topic")}
page = (RUN / "rating_template.html").read_text().replace(
    "__ITEMS__", json.dumps(items, ensure_ascii=False).replace("</", "<\\/"))
(RUN / "rating.html").write_text(page)
(RUN / "blind_key.json").write_text(json.dumps(key, ensure_ascii=False, indent=1) + "\n")
print("items", len(items))
