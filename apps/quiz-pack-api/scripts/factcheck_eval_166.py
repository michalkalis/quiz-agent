"""#166 increment 3 — validate cheaper fact-check variants on the D21b set.

Acceptance bar (founder 2026-08-24): recall 6/6 on the known D21b errors
(q03/q18/q32/q48/q63/q81) and no increase in false alarms on the 94 clean
questions. A variant that misses the bar does not ship.

Variants:
  search              Tavily evidence for every question (2 advanced queries,
                      shared by both arbiters) -> evidence.jsonl
  judge --model M     single-turn arbiter over stored evidence -> judge_<M>.jsonl
  native --max-searches N
                      in-pipeline FactVerifier (Claude + native web_search)
                      with a reduced search cap -> native_<N>.jsonl
  report FILE...      recall / false-alarm / cost metrics per verdicts file

All phases append JSONL per question and skip already-done qids on rerun
(durable resume). Usage (from apps/quiz-pack-api/, .env loaded by factory):

    uv run --no-sync python scripts/factcheck_eval_166.py search
    uv run --no-sync python scripts/factcheck_eval_166.py judge --model claude-haiku-4-5
    uv run --no-sync python scripts/factcheck_eval_166.py judge --model claude-sonnet-5
    uv run --no-sync python scripts/factcheck_eval_166.py native --max-searches 3
    uv run --no-sync python scripts/factcheck_eval_166.py report out/*.jsonl
"""

import argparse
import asyncio
import datetime
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from quiz_shared.paths import load_dotenv_from_ancestors  # noqa: E402

load_dotenv_from_ancestors(Path(__file__).resolve())

RUN_DIR = (
    Path(__file__).resolve().parents[3]
    / "docs" / "testing" / "runs" / "d21b-round-2026-08-18"
)
OUT_DIR = RUN_DIR / "factcheck-eval-166"

BAD_QIDS = frozenset({"q03", "q18", "q32", "q48", "q63", "q81"})
CONCURRENCY = 8

# List prices USD/1M (Haiku is eval-only, not in app.llm_usage's prod table).
_PRICES = {
    "claude-haiku-4-5": (1.00, 5.00),
    "claude-sonnet-5": (3.00, 15.00),
}
# Tavily pay-as-you-go: $0.008/credit, advanced search = 2 credits.
_TAVILY_CENTS_PER_ADVANCED_SEARCH = 1.6


def load_questions() -> list[dict]:
    """The 100 published D21b questions with answers, keyed q01..q100."""
    mapping = json.loads((RUN_DIR / "mapping.json").read_text())
    answers: dict[str, object] = {}
    for arm_file in RUN_DIR.glob("*.dedup.json"):
        for item in json.loads(arm_file.read_text()):
            answers[item["id"]] = item["correct_answer"]
    out = []
    for qid, entry in sorted(mapping.items()):
        answer = answers[entry["original_id"]]
        if isinstance(answer, list):
            answer = ", ".join(str(a) for a in answer)
        out.append(
            {
                "qid": qid,
                "arm": entry["arm"],
                "topic": entry["topic"],
                "question": entry["question"],
                "answer": str(answer),
            }
        )
    if len(out) != 100:
        raise SystemExit(f"expected 100 questions, got {len(out)}")
    return out


def done_qids(path: Path) -> set[str]:
    if not path.exists():
        return set()
    return {json.loads(line)["qid"] for line in path.read_text().split("\n") if line}


def append_jsonl(path: Path, record: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


# ---------------------------------------------------------------- search ----

async def cmd_search() -> None:
    """Phase 1: Tavily evidence per question, shared by every judge run.

    Two advanced-depth queries per question — the old verify's failure mode
    was ONE confirmation-biased query with thin snippets, so: (a) question +
    claimed answer (direct verification), (b) question alone (independent
    answer discovery — surfaces the actual record-holder / date when the
    claimed one is wrong or superseded).
    """
    import os

    from tavily import AsyncTavilyClient

    client = AsyncTavilyClient(api_key=os.environ["TAVILY_API_KEY"])
    out_path = OUT_DIR / "evidence.jsonl"

    # A record with a failed search is not "done" — drop it so the rerun
    # re-fetches that question (Tavily rate limits surfaced as errors).
    if out_path.exists():
        good = [
            line
            for line in out_path.read_text().split("\n")
            if line and not any(s.get("error") for s in json.loads(line)["searches"])
        ]
        out_path.write_text("\n".join(good) + ("\n" if good else ""))

    done = done_qids(out_path)
    questions = [q for q in load_questions() if q["qid"] not in done]
    print(f"search: {len(questions)} to do ({len(done)} already stored)")

    # Tavily dev-tier rate limit is low; keep this phase slow and retry 429s.
    sem = asyncio.Semaphore(2)

    async def tavily_search(query: str) -> dict:
        delay = 3.0
        for attempt in range(6):
            try:
                return await client.search(
                    query=query,
                    max_results=5,
                    include_answer=True,
                    search_depth="advanced",
                    timeout=15.0,
                )
            except Exception as e:
                if "excessive requests" not in str(e) or attempt == 5:
                    raise
                await asyncio.sleep(delay)
                delay *= 2
        raise RuntimeError("unreachable")

    async def one(q: dict) -> None:
        async with sem:
            queries = [
                f"{q['question']} {q['answer']}"[:390],
                q["question"][:390],
            ]
            searches = []
            for query in queries:
                try:
                    res = await tavily_search(query)
                except Exception as e:  # fail loud per question, keep the run
                    searches.append({"query": query, "error": str(e)})
                    continue
                searches.append(
                    {
                        "query": query,
                        "answer": res.get("answer"),
                        "results": [
                            {
                                "url": r.get("url"),
                                "title": r.get("title"),
                                "content": r.get("content"),
                                "score": r.get("score"),
                                "published_date": r.get("published_date"),
                            }
                            for r in res.get("results", [])
                        ],
                    }
                )
            append_jsonl(out_path, {"qid": q["qid"], "searches": searches})
            print(f"  {q['qid']} done")

    await asyncio.gather(*(one(q) for q in questions))
    print(f"evidence -> {out_path}")


# ----------------------------------------------------------------- judge ----

_JUDGE_PROMPT = """You are an adversarial fact-checker for a trivia quiz. Today is {today}. Your job is to find problems with a question-answer pair, not to confirm it. The question may have been written months ago: superlative or "only/most recent/current" claims can have been overtaken by newer events. Both the claimed answer AND every factual premise stated inside the question must be correct.

QUESTION: {question}
CLAIMED ANSWER: {claimed_answer}
TOPIC: {topic}

Below is web search evidence gathered for this pair (two searches: one for the pair, one for the question alone). Source credibility tier is marked per result.

{evidence}

Judge ONLY from the evidence above plus well-established common knowledge. Actively look for contradictions: a different record-holder, a different count or date, a newer event that supersedes the claim, or a premise in the question that the evidence contradicts.

Check every specific number, year, and date the question asserts against the evidence — including incidental ones. Example: a question opening "In 2025's <film>..." is a fact_error if the evidence shows the film premiered in 2026, even when the rest of the pair checks out. Source URLs and publication dates count as evidence for dating events.

Calibration: report a problem ONLY when the evidence clearly contradicts a specific claim in the pair. Do not flag: imprecise-but-defensible wording (e.g. "stone" for limestone), present tense for a record that still stood when the question was written, extra detail the sources add beyond the answer, or a technicality a pub-quiz host would wave through. A quizmaster reads your verdict and drops the question — a wrong drop wastes a good question, a wrong keep ships an error; both matter.

Give exactly one verdict:
- "fact_error" — the claimed answer is factually wrong, or the question asserts something false
- "logic_flaw" — the question is ambiguous, self-contradictory, or has multiple defensible answers
- "stale" — the pair was true once but has been superseded by newer events
- "ok" — the evidence is consistent with the pair and you found no problem
- "insufficient_evidence" — the evidence neither supports nor contradicts the pair well enough to judge

Reply with ONLY a single JSON object:
{{"verdict": "ok|fact_error|logic_flaw|stale|insufficient_evidence", "confidence": "high|medium|low", "note": "one-sentence justification citing the decisive source URL", "correct_answer": "the actual answer if the claimed one is wrong, else null"}}"""


def _format_evidence(searches: list[dict]) -> str:
    """Compress stored Tavily output: dedupe by URL, rank by score, trim."""
    from app.sourcing.web_search_source import classify_credibility

    seen: dict[str, dict] = {}
    answers = []
    for s in searches:
        if s.get("error"):
            continue
        if s.get("answer"):
            answers.append(s["answer"])
        for r in s.get("results", []):
            url = r.get("url") or ""
            prev = seen.get(url)
            if prev is None or (r.get("score") or 0) > (prev.get("score") or 0):
                seen[url] = r
    ranked = sorted(seen.values(), key=lambda r: r.get("score") or 0, reverse=True)[:8]
    blocks = []
    for i, r in enumerate(ranked, 1):
        date = f" ({r['published_date']})" if r.get("published_date") else ""
        blocks.append(
            f"[{i}] {r.get('title', '')}{date}\n"
            f"URL: {r.get('url')} [credibility: {classify_credibility(r.get('url') or '')}]\n"
            f"{(r.get('content') or '')[:1200]}"
        )
    parts = []
    if answers:
        parts.append("SEARCH ENGINE SUMMARIES:\n" + "\n".join(f"- {a}" for a in answers))
    parts.append("SOURCES:\n" + "\n\n".join(blocks) if blocks else "SOURCES: (none)")
    return "\n\n".join(parts)


async def cmd_judge(model: str) -> None:
    """Phase 2: one single-turn arbiter call per question over stored evidence."""
    from quiz_shared.llm import factory as llm_factory
    from app.verification.fact_verifier import _parse_verdict_json

    evidence_path = OUT_DIR / "evidence.jsonl"
    evidence = {
        rec["qid"]: rec["searches"]
        for rec in (
            json.loads(line)
            for line in evidence_path.read_text().split("\n")
            if line
        )
    }
    out_path = OUT_DIR / f"judge_{model.replace('/', '_')}.jsonl"
    done = done_qids(out_path)
    questions = [q for q in load_questions() if q["qid"] not in done]
    print(f"judge[{model}]: {len(questions)} to do ({len(done)} stored)")

    client = llm_factory.anthropic_client()
    today = datetime.date.today().isoformat()
    in_price, out_price = _PRICES[model]
    sem = asyncio.Semaphore(CONCURRENCY)

    async def one(q: dict) -> None:
        async with sem:
            prompt = _JUDGE_PROMPT.format(
                today=today,
                question=q["question"],
                claimed_answer=q["answer"],
                topic=q["topic"],
                evidence=_format_evidence(evidence[q["qid"]]),
            )
            try:
                resp = await client.messages.create(
                    model=model,
                    max_tokens=1024,
                    messages=[{"role": "user", "content": prompt}],
                )
            except Exception as e:
                append_jsonl(out_path, {"qid": q["qid"], "error": str(e)})
                print(f"  {q['qid']} ERROR {e}")
                return
            text = "".join(
                b.text for b in resp.content if getattr(b, "type", None) == "text"
            )
            data = _parse_verdict_json(text) or {}
            cost = (
                resp.usage.input_tokens * in_price
                + resp.usage.output_tokens * out_price
            ) / 1_000_000 * 100
            append_jsonl(
                out_path,
                {
                    "qid": q["qid"],
                    "arm": q["arm"],
                    "verdict": data.get("verdict", "unparseable"),
                    "confidence": data.get("confidence"),
                    "note": data.get("note"),
                    "correct_answer": data.get("correct_answer"),
                    "llm_cost_cents": round(cost, 3),
                    "tavily_cost_cents": 2 * _TAVILY_CENTS_PER_ADVANCED_SEARCH,
                    "input_tokens": resp.usage.input_tokens,
                    "output_tokens": resp.usage.output_tokens,
                },
            )
            print(f"  {q['qid']} {data.get('verdict')}")

    await asyncio.gather(*(one(q) for q in questions))
    print(f"verdicts -> {out_path}")


# ---------------------------------------------------------------- native ----

async def cmd_native(max_searches: int) -> None:
    """In-pipeline FactVerifier with a reduced web-search cap (part 3 of the
    increment-3 plan: _MAX_WEB_SEARCHES 5 -> 2-3, validated before shipping)."""
    from app.verification import fact_verifier as fv

    fv._MAX_WEB_SEARCHES = max_searches
    verifier = fv.FactVerifier()

    out_path = OUT_DIR / f"native_max{max_searches}.jsonl"
    done = done_qids(out_path)
    questions = [q for q in load_questions() if q["qid"] not in done]
    print(f"native[max_uses={max_searches}]: {len(questions)} to do ({len(done)} stored)")

    sem = asyncio.Semaphore(CONCURRENCY)

    async def one(q: dict) -> None:
        async with sem:
            result = await verifier.verify(q["question"], q["answer"], q["topic"])
            append_jsonl(
                out_path,
                {
                    "qid": q["qid"],
                    "arm": q["arm"],
                    "verdict": result.verdict,
                    "held": result.held_for_review,
                    "note": result.notes,
                    "llm_cost_cents": round(result.cost_cents, 3),
                    "tavily_cost_cents": 0.0,
                },
            )
            print(f"  {q['qid']} {result.verdict} ({result.cost_cents:.1f}c)")

    await asyncio.gather(*(one(q) for q in questions))
    print(f"verdicts -> {out_path}")


# ---------------------------------------------------------------- report ----

_PROBLEM = {"fact_error", "logic_flaw", "stale"}


def cmd_report(paths: list[str]) -> None:
    for p in paths:
        records = [json.loads(line) for line in Path(p).read_text().split("\n") if line]
        by_qid = {r["qid"]: r for r in records}
        caught = sorted(
            q for q in BAD_QIDS if by_qid.get(q, {}).get("verdict") in _PROBLEM
        )
        missed = sorted(BAD_QIDS - set(caught))
        false_alarms = sorted(
            q for q, r in by_qid.items()
            if q not in BAD_QIDS and r.get("verdict") in _PROBLEM
        )
        held = sorted(
            q for q, r in by_qid.items()
            if r.get("verdict") in ("insufficient_evidence", "unverified", "unparseable")
            or r.get("error")
        )
        llm = sum(r.get("llm_cost_cents", 0) for r in records)
        tavily = sum(r.get("tavily_cost_cents", 0) for r in records)
        n = len(records)
        print(f"\n=== {p} (n={n}) ===")
        print(f"recall:       {len(caught)}/6  caught={caught}  missed={missed}")
        print(f"false alarms: {len(false_alarms)}  {false_alarms}")
        print(f"held/unparseable: {len(held)}  {held}")
        for q in sorted(BAD_QIDS | set(false_alarms)):
            r = by_qid.get(q, {})
            tag = "BAD " if q in BAD_QIDS else "FP  "
            print(f"  {tag}{q}: {r.get('verdict')} — {str(r.get('note'))[:140]}")
        if n:
            print(
                f"cost: llm {llm:.0f}c + tavily {tavily:.0f}c = "
                f"{(llm + tavily):.0f}c total, {(llm + tavily) / n:.2f}c/question"
            )


def main() -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("search")
    j = sub.add_parser("judge")
    j.add_argument("--model", required=True, choices=sorted(_PRICES))
    n = sub.add_parser("native")
    n.add_argument("--max-searches", type=int, required=True)
    r = sub.add_parser("report")
    r.add_argument("paths", nargs="+")
    args = ap.parse_args()

    if args.cmd == "search":
        asyncio.run(cmd_search())
    elif args.cmd == "judge":
        asyncio.run(cmd_judge(args.model))
    elif args.cmd == "native":
        asyncio.run(cmd_native(args.max_searches))
    else:
        cmd_report(args.paths)


if __name__ == "__main__":
    main()
