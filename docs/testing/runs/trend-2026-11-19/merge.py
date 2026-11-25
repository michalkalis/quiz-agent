"""Merge the reviewed trend batches (2026-11-19) into one import file per language.
Keeps ids from review-<lang>.json, applies its fixes, tags the rows and gives them a
boost window, so the daily challenge and the video batch treat them as timely.
Writes merged-<lang>.json and ids.txt. Usage: python3 merge.py sk cs en"""

import json
import sys
from pathlib import Path

RUN = Path(__file__).parent
TAGS = ["trend", "trend-2026-w47"]
# Three weeks: long enough for a multi-week topic, short enough to stay current.
BOOST_UNTIL = "2026-12-10T00:00:00+00:00"

ids = []
for lang in sys.argv[1:]:
    review = json.loads((RUN / f"review-{lang}.json").read_text())
    keep = set(review["keep"])
    fixes = {}
    for f in review.get("fix", []):
        fixes.setdefault(f["id"], {})[f["field"]] = f["new"]
    batch = [q for p in sorted(RUN.glob(f"{lang}-[0-9].json")) for q in json.loads(p.read_text())]
    dropped = {d["id"] for d in review.get("drop", [])}
    assert keep | dropped == {q["id"] for q in batch} and not keep & dropped, lang
    out = []
    for q in batch:
        if q["id"] not in keep:
            continue
        q.update(fixes.get(q["id"], {}))
        assert q["language"] == lang and q.get("source_url"), q["id"]
        q["tags"] = sorted(set(q.get("tags") or []) | set(TAGS))
        q["boost_until"] = BOOST_UNTIL
        out.append(q)
    (RUN / f"merged-{lang}.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
    ids += [q["id"] for q in out]
    print(f"{lang}: {len(out)} of {len(batch)} -> merged-{lang}.json")
(RUN / "ids.txt").write_text("\n".join(ids) + "\n")
