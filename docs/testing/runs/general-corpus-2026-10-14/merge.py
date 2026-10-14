"""#203 import step: merge the full-run survivors and the rated pilot questions into merged-{en,sk,cs}.json.

Sources: this run (arms E/F en, S/T sk, C/D cs) + general-pilot + topics-pilot (variety pilot excluded, founder 2026-10-14).
Drops: ids from drops.txt (same-fact pairs, as run_dups.py prints them) and any question the founder rated <= 5 (pilots and this run's sample)
(ratings_raw/ratings/R*.json + blind_key.json in each pilot dir).
Usage: merge.py drops.txt   → writes merged-*.json next to this script and prints counts per language.
"""

import json
import sys
from pathlib import Path

RUN = Path(__file__).resolve().parent
PILOTS = [RUN.parent / "general-pilot-2026-10-14", RUN.parent / "topics-pilot-2026-10-14"]
drops = set(Path(sys.argv[1]).read_text().split())


def low_rated(pilot):
    key = json.loads((pilot / "blind_key.json").read_text())
    out = set()
    for p in (pilot / "ratings_raw" / "ratings").glob("R*.json"):
        fun = json.loads(p.read_text()).get("fun")
        if fun is not None and fun <= 5 and p.stem in key:
            out.add(key[p.stem]["qid"])
    return out


low = set().union(*(low_rated(p) for p in [RUN, *PILOTS]))  # incl. this run's blind sample
merged = {"en": [], "sk": [], "cs": []}
skipped = {"dup": 0, "low": 0}
for run in [RUN, *PILOTS]:
    for p in sorted(run.glob("[A-Z]-[0-9]*.json")):
        if p.name.endswith("usage.json"):
            continue
        for i, q in enumerate(json.loads(p.read_text()), 1):
            if f"{run.name}/{p.stem}#{i}" in drops:
                skipped["dup"] += 1
            elif q.get("id") in low:
                skipped["low"] += 1
            else:
                merged[q["language"]].append(q)

for lang, qs in merged.items():
    (RUN / f"merged-{lang}.json").write_text(json.dumps(qs, ensure_ascii=False, indent=1) + "\n")
print({k: len(v) for k, v in merged.items()}, skipped, "low-rated pilot ids:", len(low))
