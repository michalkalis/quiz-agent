"""#196 track 196.3 — answer grader + input parser: current model vs Claude Haiku 5.5.

Runs every case in a cases.jsonl through the REAL ``AnswerEvaluator.evaluate``
and ``InputParser.parse`` (same prompts, same fast paths, same verdict parsing).
Only the client + model id are swapped:

- ``gpt-4o-mini``  — prod today: OpenAI SDK client via the active gateway
  (run with ``LLM_GATEWAY=openrouter`` for prod parity), temperature 0.3.
- ``claude-haiku-5-5`` — the production Claude path of ``hot_path_llm.complete``
  (#196: direct Anthropic API, no ``temperature``, effort ``low``). The arm's
  recorder is injected as the roles' ``claude_client``, so it records exactly
  the request prod sends. ``@medium`` / ``@low`` override ``output_config``
  effort; no suffix = prod's request untouched. A Claude failure surfaces as
  an error for that case — the gpt-4o-mini fallback is disabled in the eval so
  it can never pass off a fallback verdict as Claude's.

Cases the deterministic layers decide (exact/alternative/sound-alike match,
MCQ option matcher, parser fast paths) never reach a model; a stub-client dry
run finds them and they are reported as excluded, not scored.

Usage (from apps/quiz-agent, env loaded):
    LLM_GATEWAY=openrouter python scripts/eval_hot_path_models.py CASES.jsonl OUT_DIR \
        --env-file ../../.env [--arms gpt-4o-mini,claude-haiku-5-5@medium,claude-haiku-5-5@low]
"""

from __future__ import annotations

import argparse
import asyncio
import json
import statistics
import sys
import time
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT / "apps/quiz-agent"), str(ROOT / "packages/shared")]

from app.evaluation.evaluator import AnswerEvaluator
from app.evaluation.mcq_matcher import match_option
from app.evaluation.voice_match import fold
from app.input.parser import InputParser
from quiz_shared.models.question import Question

# USD per 1M tokens (input, output). gpt-4o-mini = OpenAI list price (OpenRouter
# passes it through, plus its credit-purchase fee); Haiku 5.5 = Anthropic list
# price for prompts ≤100k tokens.
PRICES = {"gpt-4o-mini": (0.15, 0.60), "claude-haiku-5-5": (0.10, 0.50)}
SPEND_CAP_USD = 0.90


def _question(case) -> Question:
    q = case["question"]
    return Question(
        id=case["id"],
        question=q["question"],
        type="text",
        correct_answer=q["correct_answer"],
        alternative_answers=q.get("alternative_answers") or [],
        possible_answers=q.get("possible_answers"),
        topic="eval",
        category="general",
        difficulty="medium",
        language=case["lang"],
    )


# ── clients ────────────────────────────────────────────────────────────────


class Recorder:
    """Records latency + token usage of every model call one arm makes.

    OpenAI arms wrap ``chat.completions.create`` (injected as the roles'
    ``client``). Claude arms wrap the Anthropic ``messages.create`` that the
    production hot path calls (injected as the roles' ``claude_client``), with
    the same per-attempt timeout and no retry as prod.
    """

    def __init__(self, base_model: str, effort: str | None = None):
        from app import hot_path_llm

        self.base_model = base_model
        self.effort = effort
        self.calls: list[dict] = []
        self.is_claude = base_model.startswith("claude-")
        if self.is_claude:
            from anthropic import AsyncAnthropic

            self._anthropic = AsyncAnthropic(
                timeout=hot_path_llm.CLAUDE_TIMEOUT_S, max_retries=0
            )
            self.messages = SimpleNamespace(create=self._claude)
        else:
            self._openai = hot_path_llm.client()
            self.chat = SimpleNamespace(completions=SimpleNamespace(create=self._gpt))

    async def _claude(self, **request):
        if self.effort:
            request = {**request, "output_config": {"effort": self.effort}}
        t0 = time.perf_counter()
        msg = await self._anthropic.messages.create(**request)
        text = "".join(b.text for b in msg.content if b.type == "text")
        self._record(t0, msg.usage.input_tokens, msg.usage.output_tokens, text)
        return msg

    async def _gpt(self, **request):
        t0 = time.perf_counter()
        resp = await self._openai.chat.completions.create(**request)
        u = resp.usage
        self._record(
            t0, u.prompt_tokens, u.completion_tokens, resp.choices[0].message.content
        )
        return resp

    def _record(self, t0: float, tokens_in: int, tokens_out: int, raw: str) -> None:
        self.calls.append(
            {
                "latency_s": time.perf_counter() - t0,
                "in": tokens_in,
                "out": tokens_out,
                "raw": raw,
            }
        )

    def spend(self) -> float:
        pin, pout = PRICES[self.base_model]
        return sum(c["in"] * pin + c["out"] * pout for c in self.calls) / 1e6


async def _no_fallback(**request):
    raise RuntimeError("Claude call failed; eval does not fall back to gpt-4o-mini")


NO_FALLBACK = SimpleNamespace(
    chat=SimpleNamespace(completions=SimpleNamespace(create=_no_fallback))
)


def make_recorder(arm: str) -> Recorder:
    base, _, effort = arm.partition("@")
    return Recorder(base, effort or None)


def attach(rec: Recorder, *roles) -> None:
    """Point each role at the arm's recorder (see ``Recorder``)."""
    for role in roles:
        if rec.is_claude:
            role.claude_client = rec
            role.client = NO_FALLBACK
        else:
            role.client = rec


class StubCreate:
    """Dry-run client: counts calls, answers something parseable."""

    def __init__(self):
        self.n = 0

    async def __call__(self, **request):
        self.n += 1
        content = (
            '{"intents": []}'
            if "JSON" in request["messages"][0]["content"]
            else "correct"
        )
        return SimpleNamespace(
            choices=[SimpleNamespace(message=SimpleNamespace(content=content))],
            usage=SimpleNamespace(prompt_tokens=0, completion_tokens=0),
        )


# ── one case through the real code path ────────────────────────────────────


async def run_case(case, evaluator: AnswerEvaluator, parser: InputParser) -> dict:
    q = _question(case)
    if case["role"] == "grade":
        verdict, _ = await evaluator.evaluate(case["heard"], q, q.question)
        return {"verdict": verdict}
    # Parser: replicate flow._apply_intents' deterministic pre-checks.
    heard = case["heard"]
    if heard.strip().lower() == "skip" or match_option(heard, q.possible_answers):
        return {"deterministic": True}
    intents = await parser.parse(
        user_input=heard, current_question=q.question, phase="asking"
    )
    return {"intents": intents}


def score_parse(case, intents) -> tuple[bool, str]:
    types = {i.get("intent_type") for i in intents}
    missing = [t for t in case["required"] if t not in types]
    banned = [t for t in case["forbidden"] if t in types]
    if missing or banned:
        return False, f"intents={sorted(t or '' for t in types)}"
    check = case["answer_check"]
    if check is None:
        return True, ""
    answer = next(
        (
            (i.get("extracted_data") or {}).get("answer") or ""
            for i in intents
            if i.get("intent_type") == "answer"
        ),
        "",
    )
    if check.startswith("mcq:"):
        key = match_option(answer, case["question"]["possible_answers"])
        return key == check[4:], f"answer={answer!r}→{key}"
    return fold(check) in fold(answer), f"answer={answer!r}"


async def dry_run(cases) -> set[str]:
    """IDs of cases that reach an LLM (anything else is decided deterministically)."""
    reach = set()
    for case in cases:
        stub = StubCreate()
        # Non-Claude model id: the stub must be the only client ever called.
        ev, pa = AnswerEvaluator(model="gpt-4o-mini"), InputParser(model="gpt-4o-mini")
        ev.client = pa.client = SimpleNamespace(
            chat=SimpleNamespace(completions=SimpleNamespace(create=stub))
        )
        await run_case(case, ev, pa)
        if stub.n:
            reach.add(case["id"])
    return reach


async def run_arm(arm: str, cases, concurrency: int) -> list[dict]:
    base = arm.partition("@")[0]
    rec = make_recorder(arm)
    sem = asyncio.Semaphore(concurrency)
    out = []

    async def one(case):
        async with sem:
            if rec.spend() > SPEND_CAP_USD:
                raise SystemExit(f"spend cap hit on {arm}")
            ev, pa = AnswerEvaluator(model=base), InputParser(model=base)
            attach(rec, ev, pa)
            n0 = len(rec.calls)
            try:
                res = await run_case(case, ev, pa)
            except Exception as exc:  # noqa: BLE001 — recorded, not hidden
                res = {"error": f"{type(exc).__name__}: {exc}"[:300]}
            calls = rec.calls[n0:]
            res.update(id=case["id"], arm=arm, calls=calls)
            out.append(res)

    await asyncio.gather(*(one(c) for c in cases))
    print(f"{arm}: {len(rec.calls)} calls, ${rec.spend():.4f}", file=sys.stderr)
    return out


def summarize(cases_by_id, results, arm) -> dict:
    rows = [r for r in results if r["arm"] == arm]
    lat = [c["latency_s"] for r in rows for c in r["calls"]]
    base = arm.partition("@")[0]
    pin, pout = PRICES[base]
    s = {"arm": arm, "errors": sum("error" in r for r in rows)}
    for role in ("grade", "parse"):
        rr = [
            r for r in rows if cases_by_id[r["id"]]["role"] == role and "error" not in r
        ]
        calls = [c for r in rr for c in r["calls"]]
        cost_per_call = (
            (sum(c["in"] * pin + c["out"] * pout for c in calls) / len(calls) / 1e6)
            if calls
            else 0
        )
        lat_r = sorted(c["latency_s"] for c in calls)
        d = {
            "n": len(rr),
            "cost_per_1000": cost_per_call * 1000,
            "median_s": statistics.median(lat_r) if lat_r else None,
            "p90_s": lat_r[int(0.9 * (len(lat_r) - 1))] if lat_r else None,
            "avg_in": statistics.mean(c["in"] for c in calls) if calls else 0,
            "avg_out": statistics.mean(c["out"] for c in calls) if calls else 0,
        }
        if role == "grade":
            fi = fc = partial = ok = 0
            for r in rr:
                exp, got = cases_by_id[r["id"]]["expected"], r["verdict"]
                if got == exp:
                    ok += 1
                elif exp == "correct" and got in ("incorrect", "partially_incorrect"):
                    fi += 1
                elif exp == "incorrect" and got == "correct":
                    fc += 1
                else:
                    partial += 1
            d.update(
                accuracy=ok / len(rr) if rr else 0,
                false_incorrect=fi,
                false_correct=fc,
                partial_other=partial,
            )
        else:
            ok = sum(score_parse(cases_by_id[r["id"]], r["intents"])[0] for r in rr)
            d.update(accuracy=ok / len(rr) if rr else 0)
        s[role] = d
    s["all_calls_median_s"] = statistics.median(lat) if lat else None
    return s


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cases")
    ap.add_argument("out_dir")
    ap.add_argument("--arms", default="gpt-4o-mini,claude-haiku-5-5")
    ap.add_argument("--concurrency", type=int, default=3)
    ap.add_argument("--limit", type=int)
    ap.add_argument(
        "--env-file", help="dotenv file to load (does not override set vars)"
    )
    args = ap.parse_args()
    if args.env_file:
        from dotenv import load_dotenv

        load_dotenv(args.env_file, override=False)

    cases = [
        json.loads(line)
        for line in Path(args.cases).read_text().splitlines()
        if line.strip()
    ]
    reach = await dry_run(cases)
    excluded = [c for c in cases if c["id"] not in reach]
    cases = [c for c in cases if c["id"] in reach][: args.limit]
    print(
        f"{len(cases)} cases reach a model, {len(excluded)} decided deterministically",
        file=sys.stderr,
    )

    results = []
    for arm in args.arms.split(","):
        results += await run_arm(arm, cases, args.concurrency)

    by_id = {c["id"]: c for c in cases}
    summary = [summarize(by_id, results, arm) for arm in args.arms.split(",")]
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "results.json").write_text(
        json.dumps(
            {
                "summary": summary,
                "excluded_deterministic": [c["id"] for c in excluded],
                "results": results,
            },
            ensure_ascii=False,
            indent=1,
        )
    )
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    asyncio.run(main())
