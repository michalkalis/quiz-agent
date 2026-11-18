"""#233 233.2: topic check eval. Usage: python run_eval.py <model-id> [cases.json]"""

import asyncio, json, sys
from pathlib import Path
from app.topic_check import check_topic


async def main(model: str) -> None:
    cases = json.loads((Path(__file__).parent / "cases.json").read_text())
    got = await asyncio.gather(*(check_topic(p, model=model) for _, _, p in cases))
    wrong = 0
    for (exp, lang, p), (v, failed) in zip(cases, got):
        mark = "  " if v == exp else "XX"
        wrong += v != exp
        print(
            f"{mark} exp={exp:<8} got={v:<8}{' FAILED' if failed else ''}  [{lang}] {p[:70]}"
        )
    print(f"{model}: {len(cases) - wrong}/{len(cases)} correct")


asyncio.run(main(sys.argv[1]))
