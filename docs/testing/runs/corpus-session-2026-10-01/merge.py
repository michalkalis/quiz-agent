"""Merge generation batches of the 2026-10-01 session into one import file, dropping rows found to
duplicate the live prod corpus (keyword check via check_dups.sh) or another row in the same run.
Drops live in drops.json as {"<batch>:<1-based index>": "<reason>"} so each round appends its own.

    python merge.py --out merged-r1.json 01 02 03 04 05 06 07 08
"""

import argparse
import json
from pathlib import Path

RUN = Path(__file__).parent
ap = argparse.ArgumentParser()
ap.add_argument("--out", required=True)
ap.add_argument("batches", nargs="+")
args = ap.parse_args()
drops_path = RUN / "drops.json"
DROPS = json.load(drops_path.open()) if drops_path.exists() else {}
out, dropped = [], 0
for b in args.batches:
    p = RUN / f"batch-{b}.json"
    if not p.exists():
        print(f"skip missing {p.name}")
        continue
    for i, q in enumerate(json.load(p.open()), 1):
        key = f"{b}:{i}"
        if key in DROPS:
            dropped += 1
            print(f"drop batch-{b} #{i}: {q['question'][:70]}… — {DROPS[key]}")
            continue
        out.append(q)
mcq = sum("multichoice" in q["type"] for q in out)
nosrc = sum(not q.get("source_url") for q in out)
dst = RUN / args.out
json.dump(out, dst.open("w"), indent=2, ensure_ascii=False)
print(f"merged: {len(out)} q ({len(out) - mcq} open / {mcq} MCQ), dropped {dropped}, no source {nosrc} → {dst.name}")
