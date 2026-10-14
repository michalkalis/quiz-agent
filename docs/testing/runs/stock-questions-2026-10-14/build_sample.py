"""#203: blind founder check of the stock-question verdicts.

15 questions the check flags + 15 it keeps, drawn from verdicts.json with a
fixed seed and shuffled. The key (verdict per item) stays in blind_key.json,
never in the page.
"""

import json
import random
from pathlib import Path

RUN = Path(__file__).parent
PER_ARM = 15

records = json.loads((RUN / "verdicts.json").read_text())
rng = random.Random(203)
picks = [("stock", r) for r in rng.sample([r for r in records if r["stock"]], PER_ARM)] + [
    ("keep", r) for r in rng.sample([r for r in records if r["stock"] is False], PER_ARM)
]
rng.shuffle(picks)
items, key = [], {}
for i, (arm, r) in enumerate(picks, 1):
    rid = f"Q{i}"
    items.append({
        "id": rid,
        "lang": r["language"] or "en",
        "question": r["question"],
        "answer": str(r["answer"]),
        "options": r["options"] or [],
        "explanation": "",
    })
    key[rid] = {"arm": arm, "qid": r["id"], "category": r["category"], "reason": r["reason"]}

page = (RUN / "rating_template.html").read_text().replace(
    "__ITEMS__", json.dumps(items, ensure_ascii=False).replace("</", "<\\/")
)
(RUN / "rating.html").write_text(page)
(RUN / "blind_key.json").write_text(json.dumps(key, ensure_ascii=False, indent=1) + "\n")
print("items", len(items))
