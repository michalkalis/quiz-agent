"""#201.4: build the blind rating page + key from the four arm outputs.

en: 10 from A, 10 B questions the casual-player check passed, up to 5 it would drop.
sk: 8 / 8 / up to 4. Shuffled per language with a fixed seed; the key (arm + verdict)
stays in blind_key.json, never in the page.
"""

import json
import random
from pathlib import Path

RUN = Path(__file__).parent
QUOTAS = {"en": (10, 10, 5), "sk": (8, 8, 4)}


def load(name):
    path = RUN / f"{name}.json"
    return json.loads(path.read_text()) if path.exists() else []


def verdict(q):
    return ((q.get("generation_metadata") or {}).get("extra") or {}).get("casual_player")


def options(q):
    pa = q.get("possible_answers") or {}
    return [str(v) for _, v in sorted(pa.items())] if isinstance(pa, dict) else []


rng = random.Random(201)
items, key = [], {}
for lang, (n_a, n_pass, n_drop) in QUOTAS.items():
    a = load(f"A-{lang}")
    b = load(f"B-{lang}")
    b_pass = [q for q in b if verdict(q) and not verdict(q)["would_drop"]]
    b_drop = [q for q in b if verdict(q) and verdict(q)["would_drop"]]
    picks = (
        [("A", q) for q in rng.sample(a, min(n_a, len(a)))]
        + [("B-pass", q) for q in rng.sample(b_pass, min(n_pass, len(b_pass)))]
        + [("B-drop", q) for q in rng.sample(b_drop, min(n_drop, len(b_drop)))]
    )
    rng.shuffle(picks)
    prefix = "E" if lang == "en" else "S"
    for i, (arm, q) in enumerate(picks, 1):
        rid = f"{prefix}{i}"
        items.append({
            "id": rid,
            "lang": lang,
            "question": q["question"],
            "answer": str(q["correct_answer"]),
            "options": options(q),
            "explanation": q.get("explanation") or "",
        })
        key[rid] = {"arm": arm, "qid": q.get("id"), "casual_player": verdict(q)}
    print(lang, "A", len(a), "B", len(b), "B-pass", len(b_pass), "B-drop", len(b_drop),
          "picked", len(picks))

page = (RUN / "rating_template.html").read_text().replace(
    "__ITEMS__", json.dumps(items, ensure_ascii=False).replace("</", "<\\/")
)
(RUN / "rating.html").write_text(page)
(RUN / "blind_key.json").write_text(json.dumps(key, ensure_ascii=False, indent=1))
print("items", len(items))
