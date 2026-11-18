"""Merge the reviewed Christmas 2026 batches into one import file per language (#241).
Keeps ids from review-<lang>.json, applies its fixes plus EXTRA below, tags the rows
and writes merged-<lang>.json and ids.txt (all ids, for the 1 Dec boost).
Usage: python3 merge.py sk cs en"""

import json
import sys
from pathlib import Path

RUN = Path(__file__).parent
# Session decisions on top of the reviewers' files (id prefix -> reason / fix).
EXTRA_DROPS = {
    "a3e283b4": "UAE poppy-seed ban: can change and off the festive mood",
}
EXTRA_FIXES = {
    "4862614d": {
        "source_url": "https://sk.wikipedia.org/wiki/Kapustnica",
        "source_excerpt": "Do pôstnej katolíckej vianočnej (Štedrý deň) sa nedáva mäso, "
        "zahusťuje sa napr. bielymi hladkými haluškami, smotanou a rozotreným zemiakom.",
    },
}
TEXT_FIXES = {
    # Wichern's Rauhes Haus was a home for poor children, not strictly an orphanage.
    "03ac60b8": ("question", "deti v sirotinci", "deti v detskom domove"),
    "c86f9ed3": ("question", "pro děti ze sirotčince", "pro chudé děti ze svého domova"),
}
TAGS = ["christmas", "christmas-2026"]


def load(lang):
    for p in sorted(RUN.glob(f"{lang}-[0-9].json")):
        yield from json.loads(p.read_text())


ids = []
for lang in sys.argv[1:]:
    review = json.loads((RUN / f"review-{lang}.json").read_text())
    keep = set(review["keep"])
    fixes = {}
    for f in review.get("fix", []):
        fixes.setdefault(f["id"], {})[f["field"]] = f["new"]
    out = []
    for q in load(lang):
        if q["id"] not in keep or q["id"][:8] in EXTRA_DROPS:
            continue
        q.update(fixes.get(q["id"], {}))
        q.update(EXTRA_FIXES.get(q["id"][:8], {}))
        if q["id"][:8] in TEXT_FIXES:
            field, old, new = TEXT_FIXES[q["id"][:8]]
            assert old in q[field], (q["id"], old)
            q[field] = q[field].replace(old, new)
        assert q["language"] == lang and q.get("source_url"), q["id"]
        q["tags"] = sorted(set(q.get("tags") or []) | set(TAGS))
        q["boost_until"] = None  # set on 1 Dec (issue #241, task 241.5)
        out.append(q)
    (RUN / f"merged-{lang}.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
    ids += [q["id"] for q in out]
    print(f"{lang}: {len(out)} -> merged-{lang}.json")
(RUN / "ids.txt").write_text("\n".join(ids) + "\n")
