"""Question-structure fix on stored SK/CS translations (founder 2026-09-25).

The blind test (``question_structure_arms.py``, batch ``aca4c37d``) picked arm B:
keep the approved translation and rewrite **only** the question sentence under
``translate.QUESTION_STRUCTURE_RULE``. New translations get the rule directly
(prompt ``corpus-v2``, arm A). This script applies B to the rows translated
before the rule existed:

  plan     — counts per status: rows whose English source buries the question
             word (``buries_question_word``), how many are marked / rewritten.
  mark     — flag every buried row that has not been rewritten with
             ``verification.structure_fix = "pending"``. quiz-agent excludes a
             flagged row's question from sessions in that language, so the
             unfixed word order stays out of the beta until it is rewritten.
  rewrite  — rewrite N flagged rows (approved first, spread over categories),
             drop each back to ``pending`` and run the normal #168 gate on
             exactly those rows. The gate rewrites ``verification`` wholesale,
             so a rewritten row loses the flag and becomes servable again once
             approved. Token usage per model goes to ``--usage-out``.

Usage (from apps/quiz-pack-api/, prod through the tunnel):

    uv run --no-sync python scripts/question_structure_fix.py plan --language sk --database-url URL
    uv run --no-sync python scripts/question_structure_fix.py mark --language sk --database-url URL
    uv run --no-sync python scripts/question_structure_fix.py rewrite --language sk --n 50 \\
        --database-url URL --out DIR/rewrite-sk.json --usage-out DIR/usage-sk.json \\
        --answerability-model claude-sonnet-5
"""

from __future__ import annotations

import argparse
import asyncio
import json
import random
import sys
import time
from collections import Counter, defaultdict
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import llm_usage
from quiz_shared.llm import factory
from quiz_shared.paths import load_dotenv_from_ancestors
from scripts.question_structure_arms import buries_question_word
from scripts.translation_runner import translate as tr
from scripts.translation_runner.rewrite import rewrite_question
from scripts.translation_runner.verify import _draft_payload, verify_rows
from sqlalchemy import text

FLAG = "structure_fix"
#: Suffix on ``prompt_version`` of a row whose question was rewritten by arm B.
REWRITE_SUFFIX = "+qrewrite-v1"
#: Rows the fix applies to: live rows translated before the rule existed.
FIXABLE_STATUSES = ("approved", "rejected")

_ROWS_SQL = text(
    """
    SELECT t.id, t.question_id, t.language, t.status, t.question,
           t.possible_answers, t.explanation, t.headline_answer, t.correct_answer,
           t.correct_answer_key, t.alternative_answers, t.prompt_version,
           t.verification ->> 'structure_fix' AS flag,
           q.question AS src_question, q.category AS src_category
    FROM question_translations t JOIN questions q ON q.id = t.question_id
    WHERE t.language = :language
    """
)


def needs_fix(row: dict[str, Any]) -> bool:
    """Buried English question word, translated before the rule, not yet
    rewritten. Pure so the selection rule is testable."""
    version = row.get("prompt_version") or ""
    return (
        row["status"] in FIXABLE_STATUSES
        and version != tr.PROMPT_VERSION
        and not version.endswith(REWRITE_SUFFIX)
        and buries_question_word(row["src_question"])
    )


def pick(rows: list[dict[str, Any]], n: int, seed: int) -> list[dict[str, Any]]:
    """``n`` flagged rows, approved before rejected, round-robin over category."""
    rng = random.Random(seed)
    out: list[dict[str, Any]] = []
    for status in FIXABLE_STATUSES:
        cells: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for r in rows:
            if r["status"] == status:
                cells[r.get("src_category") or ""].append(r)
        queues = [v for v in cells.values()]
        for q in queues:
            rng.shuffle(q)
        rng.shuffle(queues)
        while queues and len(out) < n:
            for q in list(queues):
                if len(out) >= n:
                    break
                out.append(q.pop())
                if not q:
                    queues.remove(q)
    return out


async def _rows(engine: Any, language: str) -> list[dict[str, Any]]:
    async with engine.connect() as conn:
        result = await conn.execute(_ROWS_SQL, {"language": language})
        return [dict(r) for r in result.mappings().all()]


async def cmd_plan(engine: Any, args: argparse.Namespace) -> int:
    rows = await _rows(engine, args.language)
    by: Counter = Counter()
    for r in rows:
        by[(r["status"], "all")] += 1
        if needs_fix(r):
            by[(r["status"], "needs_fix")] += 1
        if r["flag"] == "pending":
            by[(r["status"], "flagged")] += 1
        if (r["prompt_version"] or "").endswith(REWRITE_SUFFIX):
            by[(r["status"], "rewritten")] += 1
    for status in sorted({s for s, _ in by}):
        cols = ", ".join(f"{k} {by[(status, k)]}" for k in ("all", "needs_fix", "flagged", "rewritten"))
        print(f"{args.language} {status}: {cols}")
    return 0


async def cmd_mark(engine: Any, args: argparse.Namespace) -> int:
    ids = [r["id"] for r in await _rows(engine, args.language) if needs_fix(r) and r["flag"] != "pending"]
    async with engine.begin() as conn:
        for tid in ids:
            await conn.execute(
                text(
                    "UPDATE question_translations SET verification = "
                    "verification || jsonb_build_object('structure_fix', 'pending') WHERE id = :id"
                ),
                {"id": tid},
            )
    print(f"{args.language}: flagged {len(ids)} row(s)")
    return 0


async def cmd_rewrite(engine: Any, args: argparse.Namespace) -> int:
    recorder = llm_usage.UsageRecorder()
    factory.set_usage_handler(llm_usage.UsageCallbackHandler(recorder))
    flagged = [r for r in await _rows(engine, args.language) if r["flag"] == "pending"]
    chosen = pick(flagged, args.n, args.seed)
    print(f"{len(flagged)} flagged {args.language} rows → rewriting {len(chosen)}")

    model = tr.TRANSLATION_MODEL[args.language]
    chat = factory.chat_openai(model, max_tokens=tr.MAX_TOKENS)
    sem = asyncio.Semaphore(args.concurrency)
    log: list[dict[str, Any]] = []
    started = time.monotonic()

    async def one(row: dict[str, Any]) -> None:
        entry = {"question_id": str(row["question_id"]), "status_before": row["status"], "before": row["question"]}
        async with sem:
            token = llm_usage.current_stage.set("rewrite")
            try:
                new_q = await rewrite_question(chat, row["src_question"], _draft_payload(row), args.language)
            except Exception as exc:  # noqa: BLE001 — call boundary: the row keeps its flag
                entry["error"] = str(exc)[:300]
                log.append(entry)
                return
            finally:
                llm_usage.current_stage.reset(token)
        entry["after"] = new_q
        version = (row["prompt_version"] or "") + REWRITE_SUFFIX
        async with engine.begin() as conn:
            if new_q == row["question"]:
                # Already follows the rule: keep status, just drop the flag.
                await conn.execute(
                    text(
                        "UPDATE question_translations SET prompt_version = :v, "
                        "verification = verification - 'structure_fix', updated_at = now() WHERE id = :id"
                    ),
                    {"v": version, "id": row["id"]},
                )
                entry["unchanged"] = True
            else:
                # Back to pending so the gate below decides; the derived
                # approved_languages index must drop the language meanwhile (DD1).
                await conn.execute(
                    text(
                        "UPDATE question_translations SET question = :q, status = 'pending', "
                        "prompt_version = :v, updated_at = now() WHERE id = :id"
                    ),
                    {"q": new_q, "v": version, "id": row["id"]},
                )
                await conn.execute(
                    text(
                        "UPDATE questions SET approved_languages = "
                        "array_remove(approved_languages, :lang) WHERE id = :qid"
                    ),
                    {"lang": args.language, "qid": row["question_id"]},
                )
        log.append(entry)

    await asyncio.gather(*(one(r) for r in chosen))
    rewritten = [e["question_id"] for e in log if "after" in e and not e.get("unchanged")]
    rewrite_s = time.monotonic() - started

    token = llm_usage.current_stage.set("verify")
    try:
        outcomes = await verify_rows(
            engine,
            args.language,
            limit=len(rewritten) or 1,
            concurrency=args.concurrency,
            answerability_model=args.answerability_model,
            question_ids=rewritten,
        ) if rewritten else Counter()
    finally:
        llm_usage.current_stage.reset(token)

    final = {str(r["question_id"]): r["status"] for r in await _rows(engine, args.language)}
    for e in log:
        e["status_after"] = final.get(e["question_id"])
    summary = {
        "language": args.language,
        "finished_at": datetime.now(UTC).isoformat(),
        "chosen": len(chosen),
        "rewritten": len(rewritten),
        "unchanged": sum(1 for e in log if e.get("unchanged")),
        "failed": sum(1 for e in log if "error" in e),
        "gate": dict(outcomes),
        "rewrite_seconds": round(rewrite_s),
        "total_seconds": round(time.monotonic() - started),
    }
    Path(args.out).write_text(json.dumps({"summary": summary, "rows": log}, ensure_ascii=False, indent=2), encoding="utf-8")
    Path(args.usage_out).write_text(json.dumps(recorder.summary(), ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False))
    return 1 if summary["failed"] else 0


async def _main(args: argparse.Namespace) -> int:
    from app.db.engine import build_engine

    engine = build_engine(args.database_url)
    try:
        return await {"plan": cmd_plan, "mark": cmd_mark, "rewrite": cmd_rewrite}[args.cmd](engine, args)
    finally:
        await engine.dispose()


def main() -> int:
    load_dotenv_from_ancestors(Path(__file__).resolve())
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("plan", "mark", "rewrite"):
        s = sub.add_parser(name)
        s.add_argument("--language", choices=("sk", "cs"), required=True)
        s.add_argument("--database-url", required=True)
        if name == "rewrite":
            s.add_argument("--n", type=int, default=50)
            s.add_argument("--seed", type=int, default=2026)
            s.add_argument("--concurrency", type=int, default=4)
            s.add_argument("--answerability-model", default="claude-sonnet-5")
            s.add_argument("--out", required=True)
            s.add_argument("--usage-out", required=True)
    return asyncio.run(_main(p.parse_args()))


if __name__ == "__main__":
    raise SystemExit(main())
