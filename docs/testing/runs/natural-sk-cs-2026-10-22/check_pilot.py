"""#211 pilot: run the naturalness check on every sk/cs pilot question (not shown to the founder),
so the blind ratings can show whether flagged rows score lower. Writes naturalness.json."""
import asyncio, json, sys
from pathlib import Path
from app.generation.naturalness_check import NaturalnessChecker
from quiz_shared.models.question import Question

RUN = Path(__file__).resolve().parent
async def main():
    qs = []
    for p in sorted(RUN.glob("[AB]-[sc][ks]-*.json")):
        if p.stem.split("-")[2].isdigit():
            qs += [Question(**q) for q in json.loads(p.read_text())]
    checked = await NaturalnessChecker().label(qs)
    out = {q.id: q.generation_metadata.extra.get("naturalness") for q in qs}
    (RUN / "naturalness.json").write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n")
    print("checked", checked, "of", len(qs))
asyncio.run(main())
