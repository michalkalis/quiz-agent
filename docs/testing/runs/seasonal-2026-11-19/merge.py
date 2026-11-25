"""Merge the reviewed seasonal batches into one import file per language.
Keeps ids from review-<lang>.json, applies its fixes, tags the rows and writes
merged-<lang>.json and ids.txt (all ids, in case a boost is set before New Year's Eve).
Same shape as docs/testing/runs/christmas-2026-11-18/merge.py.
Usage: python3 merge.py sk cs en [uk]"""

import json
import sys
from pathlib import Path

RUN = Path(__file__).parent
TAGS = {"uk": ["winter-holidays", "winter-holidays-2026"]}
DEFAULT_TAGS = ["new-year", "new-year-2026"]


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
    assert set(fixes) <= keep, f"{lang}: a fix for a row that is not kept"
    out = []
    for q in load(lang):
        if q["id"] not in keep:
            continue
        q.update(fixes.get(q["id"], {}))
        assert q["language"] == lang and q.get("source_url"), q["id"]
        q["tags"] = sorted(set(q.get("tags") or []) | set(TAGS.get(lang, DEFAULT_TAGS)))
        q["boost_until"] = None
        out.append(q)
    assert len(out) == len(keep), f"{lang}: {len(keep) - len(out)} kept ids not found"
    (RUN / f"merged-{lang}.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
    ids += [q["id"] for q in out]
    print(f"{lang}: {len(out)} -> merged-{lang}.json")
with (RUN / "ids.txt").open("a") as f:
    f.write("\n".join(ids) + "\n")
