"""#201.4: run the casual-player check (verdict only) over a dry-run JSON, e.g. arm A, for the A vs B estimate comparison."""
import asyncio, json, sys
from pathlib import Path
from app.verification.casual_player import CasualPlayerChecker
from quiz_shared.models.question import Question

async def main(path):
    rows = json.loads(Path(path).read_text())
    checker = CasualPlayerChecker()
    verdicts = await asyncio.gather(*(checker.check(Question.from_dict(r), 25) for r in rows))
    out = [{"id": r.get("id"), "pct": v.pct, "giveaway": v.giveaway, "would_drop": v.drop_reason, "q": r["question"][:90]} for r, v in zip(rows, verdicts)]
    Path(path).with_suffix(".casual.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
    pcts = [o["pct"] for o in out if o["pct"] is not None]
    print(path, "n", len(out), "mean", round(sum(pcts) / max(1, len(pcts))), "would_drop", sum(1 for o in out if o["would_drop"]))

for p in sys.argv[1:]:
    asyncio.run(main(p))
