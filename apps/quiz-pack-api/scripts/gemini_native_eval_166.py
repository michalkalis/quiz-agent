"""#166 — Gemini + Google Search grounding fact-check, 20-question D21b eval.

Provider-comparison branch (founder 2026-08-26): can a cheap Gemini Flash
model with native Google Search grounding match the Anthropic/OpenAI native
checks? Same 20-question subset and the same production adversarial prompt
(``app.verification.fact_verifier._PROMPT_TEMPLATE``) for a fair comparison.

Grounding is billed per grounded REQUEST (not per individual search):
Gemini 3.x = $14/1k requests after a free 5k/month tier (verified
2026-08-26, ai.google.dev/gemini-api/docs/pricing). Costs below are nominal
list price — the free tier may cover the whole run.

Eval-only; nothing here ships to the pipeline.

Usage (from apps/quiz-pack-api/):

    uv run --no-sync python scripts/gemini_native_eval_166.py run --model gemini-3.7-flash
    uv run --no-sync python scripts/gemini_native_eval_166.py report --model gemini-3.7-flash
"""

import argparse
import asyncio
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from quiz_shared.paths import load_dotenv_from_ancestors  # noqa: E402

load_dotenv_from_ancestors(Path(__file__).resolve())
# An apps/quiz-pack-api/.env (e.g. a fly-proxy PROD_DATABASE_URL drop) shadows
# the repo-root .env in find_in_ancestors — load the root one too so the
# provider keys are always present (override=False keeps closer values).
load_dotenv_from_ancestors(Path(__file__).resolve().parents[3] / "x")

from factcheck_eval_166 import (  # noqa: E402
    OUT_DIR,
    append_jsonl,
    cmd_report,
    done_qids,
    load_questions,
)
from haiku_native_eval_166 import SUBSET  # noqa: E402

# USD/1M tokens (in, out); thinking tokens bill as output. 3.7-flash price is
# the promo rate valid through 2026-12-31; 3.5-flash assumed at the same
# Flash-class rate (its own row was not separately verified).
_PRICES = {
    "gemini-3.7-flash": (0.75, 3.75),
    "gemini-3.5-flash": (0.75, 3.75),
}
_GROUNDING_USD_PER_1K = 14.0

CONCURRENCY = 4


def _out_path(model: str) -> Path:
    return OUT_DIR / f"native_{model.replace('.', '').replace('-', '_')}.jsonl"


def _cost_cents(model: str, usage: dict, grounded: bool) -> float:
    in_p, out_p = _PRICES[model]
    out_tokens = usage.get("candidatesTokenCount", 0) + usage.get(
        "thoughtsTokenCount", 0
    )
    tokens_usd = (usage.get("promptTokenCount", 0) * in_p + out_tokens * out_p) / 1e6
    return (tokens_usd + (grounded * _GROUNDING_USD_PER_1K / 1000)) * 100


async def cmd_run(model: str) -> None:
    import httpx

    from app.verification.fact_verifier import (
        _PROMPT_TEMPLATE,
        _parse_verdict_json,
    )

    out_path = _out_path(model)
    if out_path.exists():
        good = [
            line
            for line in out_path.read_text().split("\n")
            if line and json.loads(line).get("verdict") != "unverified"
        ]
        out_path.write_text("\n".join(good) + ("\n" if good else ""))

    done = done_qids(out_path)
    questions = [
        q for q in load_questions() if q["qid"] in SUBSET and q["qid"] not in done
    ]
    print(f"gemini native[{model}]: {len(questions)} to do ({len(done)} stored)")

    url = (
        "https://generativelanguage.googleapis.com/v1beta/models/"
        f"{model}:generateContent"
    )
    # Key travels as a header, never in the URL: httpx error messages embed
    # the full request URL (query params included), and those strings get
    # persisted verbatim into the committed JSONL below on any non-2xx.
    headers = {"x-goog-api-key": os.environ["GOOGLE_API_KEY"]}
    sem = asyncio.Semaphore(CONCURRENCY)

    async def one(client: httpx.AsyncClient, q: dict) -> None:
        async with sem:
            prompt = _PROMPT_TEMPLATE.format(
                question=q["question"],
                claimed_answer=q["answer"],
                topic=q["topic"] or "n/a",
            )
            try:
                resp = await client.post(
                    url,
                    json={
                        "contents": [{"parts": [{"text": prompt}]}],
                        "tools": [{"google_search": {}}],
                    },
                    timeout=300,
                )
                resp.raise_for_status()
                d = resp.json()
                cand = d["candidates"][0]
            except Exception as e:
                append_jsonl(
                    out_path, {"qid": q["qid"], "verdict": "unverified", "note": str(e)}
                )
                print(f"  {q['qid']} ERROR {e}")
                return
            text = "".join(
                p.get("text", "") for p in cand.get("content", {}).get("parts", [])
            )
            gm = cand.get("groundingMetadata") or {}
            queries = gm.get("webSearchQueries") or []
            data = _parse_verdict_json(text) or {}
            usage = d.get("usageMetadata") or {}
            correct = data.get("correct_answer")
            append_jsonl(
                out_path,
                {
                    "qid": q["qid"],
                    "arm": q["arm"],
                    "verdict": data.get("verdict", "unverified"),
                    "note": data.get("note"),
                    "alternatives": [str(correct)] if correct else [],
                    "llm_cost_cents": round(
                        _cost_cents(model, usage, bool(queries)), 3
                    ),
                    "tavily_cost_cents": 0.0,
                    "n_search_queries": len(queries),
                    "usage": usage,
                },
            )
            print(
                f"  {q['qid']} {data.get('verdict', 'unverified')} "
                f"({len(queries)} queries)"
            )

    async with httpx.AsyncClient(headers=headers) as client:
        await asyncio.gather(*(one(client, q) for q in questions))
    print(f"verdicts -> {out_path}")


def main() -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("run", "report"):
        p = sub.add_parser(name)
        p.add_argument("--model", required=True, choices=sorted(_PRICES))
    args = ap.parse_args()
    if args.cmd == "run":
        asyncio.run(cmd_run(args.model))
    else:
        cmd_report([str(_out_path(args.model))])


if __name__ == "__main__":
    main()
