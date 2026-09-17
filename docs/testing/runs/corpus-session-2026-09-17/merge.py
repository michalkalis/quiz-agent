"""Merge the 2026-09-17 batches, dropping rows found to duplicate the live prod corpus (keyword check
via check_dups.sh) or another row in the same run. Drops are listed by (batch, 1-based index)."""

import json
import sys
from pathlib import Path

RUN = Path(__file__).parent
DROPS = {
    ("02", 9): "intra: Sahara dust → Amazon also as batch-02 #14 (open beats true/false)",
    ("02", 10): "prod pending_review: Year Without a Summer → Mount Tambora (reversed)",
    ("02", 12): "prod approved + pending_review: largest desert = Antarctica",
    ("02", 13): "prod pending_review: farthest from centre = Chimborazo",
    ("03", 3): "prod pending_review ×2: Velcro / burrs",
    ("03", 11): "prod pending_review ×2: first barcoded product 1974 chewing gum (reversed)",
    ("03", 14): "prod pending_review: bubble wrap → wallpaper",
    ("04", 9): "prod approved ×2 + pending_review ×2: Nintendo founded 1889",
}
batches = sys.argv[1:] or ["01", "02", "03", "04"]
out, dropped = [], 0
for b in batches:
    p = RUN / f"batch-{b}.json"
    if not p.exists():
        print(f"skip missing {p.name}")
        continue
    for i, q in enumerate(json.load(p.open()), 1):
        if (b, i) in DROPS:
            dropped += 1
            print(f"drop batch-{b} #{i}: {q['question'][:70]}… — {DROPS[(b, i)]}")
            continue
        out.append(q)
mcq = sum("multichoice" in q["type"] for q in out)
nosrc = sum(not q.get("source_url") for q in out)
dst = RUN / "merged.json"
json.dump(out, dst.open("w"), indent=2, ensure_ascii=False)
print(f"merged: {len(out)} q ({len(out) - mcq} open / {mcq} MCQ), dropped {dropped}, no source {nosrc} → {dst.name}")
