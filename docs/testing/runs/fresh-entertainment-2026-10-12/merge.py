"""#199 top-up 2026-10-12 — merge the fresh EN entertainment batches into one import file,
dropping rows already covered in prod, not actually fresh, weak, or off-tone (founder 10-08:
only CURRENT politics and CURRENT wars are off-limits). Drops are keyed by question-id prefix.
Usage: python3 merge.py → merged-en.json"""

import json
from pathlib import Path

RUN = Path(__file__).parent
DROPS = {
    "285710d6": "RDJ as Doctor Doom — announced in 2024, not fresh",
    "8021bd5e": "BTS Arirang — already in prod (answer Arirang)",
    "6a79d300": "Madonna 2003 VMA kiss — second Madonna/VMA row, old fact; kept 5bb8af0d",
    "602eafb6": "Esports World Cup left Riyadh — host-country context too close to current politics",
    "858a4f10": "Lollapalooza / Jane's Addiction — tenuous fresh hook, old fact",
    "2649020f": "Practical Magic 1998 — dull year question on a thin hook",
    "7d685695": "Lanterns → Green Lantern Corps — answer given away by the title",
    "c5b274fe": "Steam Frame lottery 'why' — self-evident answer (scalpers)",
}
out = []
for p in sorted(RUN.glob("en-0*.json")):
    if p.name.endswith("usage.json"):
        continue
    for q in json.load(p.open()):
        reason = DROPS.get(q["id"][:8])
        if reason:
            print(f"drop {p.stem}: {q['question'][:60]}… — {reason}")
            continue
        assert q["language"] == "en" and q.get("source_url"), (p.stem, q["id"])
        out.append(q)
print(f"en: {len(out)} kept")
(RUN / "merged-en.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
