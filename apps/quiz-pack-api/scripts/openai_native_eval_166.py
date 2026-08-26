"""#166 — OpenAI native web-search fact-check, 20-question D21b eval.

Founder ask (2026-08-26): can a cheap OpenAI model with the built-in
Responses-API ``web_search`` tool match the Anthropic native check
(Sonnet 5: 5/7 @ ~18 c/q, Haiku 4.5: 4/7 @ 6.9 c/q) at a lower price?
Same 20-question subset and the same production adversarial prompt
(``app.verification.fact_verifier._PROMPT_TEMPLATE``) for a fair comparison.

Eval-only; nothing here ships to the pipeline.

Usage (from apps/quiz-pack-api/):

    uv run --no-sync python scripts/openai_native_eval_166.py run --model gpt-5.4-mini
    uv run --no-sync python scripts/openai_native_eval_166.py recost --model gpt-5.4-mini
    uv run --no-sync python scripts/openai_native_eval_166.py report --model gpt-5.4-mini
"""

import argparse
import asyncio
import json
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


def subset40() -> list[str]:
    """SUBSET (20 flagged/candidate qids) + 20 clean questions.

    Founder ask 2026-08-26: validate gpt-5-mini on ~40 before any pipeline
    swap — the extra 20 are clean ground to measure the false-alarm rate.
    Deterministic spread: every 4th of the sorted remaining qids (q18, the
    founder-excluded indeterminate one, is skipped).
    """
    all_qids = sorted(q["qid"] for q in load_questions())
    remaining = [q for q in all_qids if q not in SUBSET and q != "q18"]
    return list(SUBSET) + remaining[::4]

# List prices USD/1M tokens (in, cached-in, out) + web search USD/1k calls.
# Verified 2026-08-26 against developers.openai.com/api/docs/pricing: web
# search (standard tool) is $10/1k calls and search-result content tokens are
# billed extra at model rates — they show up in usage.input_tokens, so token
# math below already covers them. Cached-input assumed at 10% of input.
_PRICES = {
    "gpt-5-mini": (0.25, 0.025, 2.00),
    "gpt-5.4-mini": (0.75, 0.075, 4.50),
}
_SEARCH_USD_PER_1K = 10.0

CONCURRENCY = 4
_MAX_OUTPUT_TOKENS = 4096


def _out_path(model: str, set_size: int = 20) -> Path:
    suffix = "" if set_size == 20 else f"_{set_size}"
    return OUT_DIR / f"native_openai_{model.replace('.', '')}{suffix}.jsonl"


def _cost_cents(model: str, usage: dict, n_searches: int) -> float:
    in_p, cached_p, out_p = _PRICES[model]
    cached = (usage.get("input_tokens_details") or {}).get("cached_tokens", 0)
    fresh = usage.get("input_tokens", 0) - cached
    tokens_usd = (
        fresh * in_p + cached * cached_p + usage.get("output_tokens", 0) * out_p
    ) / 1_000_000
    return (tokens_usd + n_searches * _SEARCH_USD_PER_1K / 1000) * 100


async def cmd_run(model: str, set_size: int = 20) -> None:
    from app.verification.fact_verifier import (
        _PROMPT_TEMPLATE,
        _parse_verdict_json,
    )
    from quiz_shared.llm import factory as llm_factory

    subset = SUBSET if set_size == 20 else subset40()
    out_path = _out_path(model, set_size)
    # Reuse stored 20-set verdicts (same model + prompt) so the 40-set run
    # only pays for the extra clean questions.
    base_path = _out_path(model)
    if set_size != 20 and not out_path.exists() and base_path.exists():
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(base_path.read_text())
    # A held/unverified record (API error, truncation) is not "done" — drop
    # it so a rerun retries that question.
    if out_path.exists():
        good = [
            line
            for line in out_path.read_text().split("\n")
            if line and json.loads(line).get("verdict") != "unverified"
        ]
        out_path.write_text("\n".join(good) + ("\n" if good else ""))

    done = done_qids(out_path)
    questions = [
        q for q in load_questions() if q["qid"] in subset and q["qid"] not in done
    ]
    print(f"openai native[{model}]: {len(questions)} to do ({len(done)} stored)")

    # direct=True: the Responses web_search tool is OpenAI-only, not on the
    # OpenRouter gateway.
    client = llm_factory.openai_client(async_=True, direct=True, timeout=300)
    sem = asyncio.Semaphore(CONCURRENCY)

    async def one(q: dict) -> None:
        async with sem:
            prompt = _PROMPT_TEMPLATE.format(
                question=q["question"],
                claimed_answer=q["answer"],
                topic=q["topic"] or "n/a",
            )
            try:
                resp = await client.responses.create(
                    model=model,
                    tools=[{"type": "web_search"}],
                    input=prompt,
                    max_output_tokens=_MAX_OUTPUT_TOKENS,
                )
                d = resp.model_dump()
            except Exception as e:
                append_jsonl(
                    out_path, {"qid": q["qid"], "verdict": "unverified", "note": str(e)}
                )
                print(f"  {q['qid']} ERROR {e}")
                return
            n_searches = sum(
                1 for item in d.get("output", []) if item.get("type") == "web_search_call"
            )
            text = "".join(
                c.get("text", "")
                for item in d.get("output", [])
                if item.get("type") == "message"
                for c in item.get("content", [])
            )
            data = _parse_verdict_json(text) or {}
            usage = d.get("usage") or {}
            correct = data.get("correct_answer")
            append_jsonl(
                out_path,
                {
                    "qid": q["qid"],
                    "arm": q["arm"],
                    "verdict": data.get("verdict", "unverified"),
                    "note": data.get("note"),
                    "alternatives": [str(correct)] if correct else [],
                    "llm_cost_cents": round(_cost_cents(model, usage, n_searches), 3),
                    "tavily_cost_cents": 0.0,
                    "n_searches": n_searches,
                    "usage": usage,
                },
            )
            print(f"  {q['qid']} {data.get('verdict', 'unverified')} ({n_searches} searches)")

    await asyncio.gather(*(one(q) for q in questions))
    print(f"verdicts -> {out_path}")


def cmd_recost(model: str, set_size: int = 20) -> None:
    """Rewrite llm_cost_cents from stored usage after a price correction."""
    out_path = _out_path(model, set_size)
    records = [json.loads(line) for line in out_path.read_text().split("\n") if line]
    for r in records:
        if "usage" in r:
            r["llm_cost_cents"] = round(
                _cost_cents(model, r["usage"], r.get("n_searches", 0)), 3
            )
    out_path.write_text(
        "\n".join(json.dumps(r, ensure_ascii=False) for r in records) + "\n"
    )
    print(f"recosted {len(records)} records -> {out_path}")


def main() -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("run", "recost", "report"):
        p = sub.add_parser(name)
        p.add_argument("--model", required=True, choices=sorted(_PRICES))
        p.add_argument("--set", type=int, default=20, choices=(20, 40))
    args = ap.parse_args()
    if args.cmd == "run":
        asyncio.run(cmd_run(args.model, args.set))
    elif args.cmd == "recost":
        cmd_recost(args.model, args.set)
    else:
        cmd_report([str(_out_path(args.model, args.set))])


if __name__ == "__main__":
    main()
