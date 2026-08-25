"""#166 — Haiku 4.5 native web-search fact-check, 20-question D21b eval.

Founder ask (2026-08-25): can the full-quality native check (Anthropic API +
server-side web search, today Sonnet 5 at ~18 c/q) run on Haiku 4.5 at half
the token price? Validate on a reduced 20-question set: the 7 reference
errors + 13 flagged/false-alarm candidates from the Bedrock verifier runs.

Eval-only adaptations (no prod code touched):
- Haiku 4.5 does not support ``web_search_20260209`` (4.6+ only) — a proxy
  client rewrites the tool to the basic ``web_search_20250305``.
- ``llm_usage`` has no Haiku price row — patched in at runtime ($1/$5 per M).

Usage (from apps/quiz-pack-api/):

    uv run --no-sync python scripts/haiku_native_eval_166.py run
    uv run --no-sync python scripts/haiku_native_eval_166.py report
"""

import argparse
import asyncio
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from quiz_shared.paths import load_dotenv_from_ancestors  # noqa: E402

load_dotenv_from_ancestors(Path(__file__).resolve())

from factcheck_eval_166 import (  # noqa: E402
    OUT_DIR,
    append_jsonl,
    cmd_report,
    done_qids,
    load_questions,
)

MODEL = "claude-haiku-4-5"
OUT_PATH = OUT_DIR / "native_haiku45.jsonl"

# 7 founder-confirmed errors + 13 flagged/false-alarm candidates (Bedrock
# verifier v1/v2 union: the 6 flagged by both runs, the earlier report's
# real-error candidates, founder-cleared q37, and 3 diverse extras).
ERROR_QIDS = ["q03", "q32", "q48", "q63", "q81", "q89", "q95"]
CANDIDATE_QIDS = [
    "q45", "q68", "q70", "q73", "q76", "q91",  # flagged by both Bedrock runs
    "q02", "q28", "q58",                        # real-error candidates
    "q37",                                      # founder-cleared, re-flagged
    "q07", "q40", "q77",                        # diverse extras (v1 flags)
]
SUBSET = ERROR_QIDS + CANDIDATE_QIDS

CONCURRENCY = 4


class _ToolRewriteMessages:
    """messages.create proxy: downgrade the web-search tool for Haiku."""

    def __init__(self, real):
        self._real = real

    async def create(self, **kwargs):
        tools = [
            {**t, "type": "web_search_20250305"}
            if t.get("type", "").startswith("web_search")
            else t
            for t in kwargs.get("tools", [])
        ]
        return await self._real.messages.create(**{**kwargs, "tools": tools})


class _ToolRewriteClient:
    def __init__(self, real):
        self.messages = _ToolRewriteMessages(real)


async def cmd_run() -> None:
    from quiz_shared.llm import factory as llm_factory
    from app import llm_usage
    from app.verification.fact_verifier import FactVerifier

    llm_usage._PRICE_TABLE_USD_PER_1M[MODEL] = {"input": 1.00, "output": 5.00}
    llm_usage._PRICE_KEYS_BY_LENGTH_DESC = sorted(
        llm_usage._PRICE_TABLE_USD_PER_1M, key=len, reverse=True
    )

    verifier = FactVerifier(model=MODEL)
    verifier._client = _ToolRewriteClient(llm_factory.anthropic_client())

    # A held/unverified record (API error, e.g. empty credit balance) is not
    # "done" — drop it so a rerun retries that question.
    if OUT_PATH.exists():
        good = [
            line
            for line in OUT_PATH.read_text().split("\n")
            if line and json.loads(line).get("verdict") != "unverified"
        ]
        OUT_PATH.write_text("\n".join(good) + ("\n" if good else ""))

    done = done_qids(OUT_PATH)
    questions = [
        q for q in load_questions() if q["qid"] in SUBSET and q["qid"] not in done
    ]
    print(f"haiku native: {len(questions)} to do ({len(done)} stored)")

    sem = asyncio.Semaphore(CONCURRENCY)

    async def one(q: dict) -> None:
        async with sem:
            result = await verifier.verify(q["question"], q["answer"], q["topic"])
            append_jsonl(
                OUT_PATH,
                {
                    "qid": q["qid"],
                    "arm": q["arm"],
                    "verdict": result.verdict,
                    "held": result.held_for_review,
                    "note": result.notes,
                    "alternatives": result.alternative_answers,
                    "llm_cost_cents": round(result.cost_cents, 3),
                    "tavily_cost_cents": 0.0,
                },
            )
            print(f"  {q['qid']} {result.verdict} ({result.cost_cents:.1f}c)")

    await asyncio.gather(*(one(q) for q in questions))
    print(f"verdicts -> {OUT_PATH}")


def main() -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("run")
    sub.add_parser("report")
    args = ap.parse_args()
    if args.cmd == "run":
        asyncio.run(cmd_run())
    else:
        cmd_report([str(OUT_PATH)])


if __name__ == "__main__":
    main()
