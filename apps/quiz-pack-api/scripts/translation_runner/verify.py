"""``verify``, ``review-export``, ``corrections`` and ``glossary`` (T16, DD12, DD13).

The gate per pending row: deterministic guards → delta answerability → MQM-Quiz
judge → regional flag, the whole outcome persisted under
``question_translations.verification``. Approval rules (Session K prompt): any
guard failure, a ``translation_flip`` or a critical judge finding **rejects**;
an unavailable judge or answerability leg leaves the row **pending**
(fail-closed, retry can still approve); the regional flag never blocks
(locked decision 3(d) — ``approval_status`` cannot even read it).

When a row is approved its language joins ``questions.approved_languages`` in
the same transaction; on any other outcome it is removed (DD1: the column is a
derived index of this table and the two must never disagree).
"""

from __future__ import annotations

import asyncio
import json
from collections import Counter
from collections.abc import Callable
from datetime import UTC, datetime
from typing import Any

from app.translation_verification.answerability import DeltaAnswerabilityChecker
from app.translation_verification.draft import TranslatedDraft
from app.translation_verification.guards import run_guards
from app.translation_verification.judge import TranslationJudge, approval_status
from app.translation_verification.regional import RegionalClassifier
from quiz_shared.database.pgvector_client import questions_table
from quiz_shared.database.translation_queries import question_translations_table
from sqlalchemy import func, literal_column, select, text, update
from sqlalchemy.ext.asyncio import AsyncEngine

from .workset import SOURCE_COLUMNS, row_source_hash, source_fields, source_question

_ROW_COLUMNS = (
    "id",
    "question_id",
    "language",
    "status",
    "question",
    "possible_answers",
    "explanation",
    "headline_answer",
    "correct_answer",
    "correct_answer_key",
    "alternative_answers",
    "source_hash",
)


async def _pending_rows(
    engine: AsyncEngine,
    language: str,
    limit: int,
    status: str = "pending",
    only_answerability_flips: bool = False,
) -> list[dict[str, Any]]:
    """Translation rows joined with their English source (``src_*`` keys).

    ``only_answerability_flips`` restricts to rows whose stored verdict was a
    ``translation_flip`` (#168 re-gate of rows rejected by a weak answerability
    model); the JSONB column is outside the shared table surface, same as the
    raw-SQL write in ``_write_verdict``.
    """
    tt, qt = question_translations_table, questions_table
    stmt = (
        select(
            *[tt.c[c].label(c) for c in _ROW_COLUMNS],
            *[qt.c[c].label(f"src_{c}") for c in SOURCE_COLUMNS],
        )
        .select_from(tt.join(qt, qt.c.id == tt.c.question_id))
        .where(tt.c.language == language, tt.c.status == status)
    )
    if only_answerability_flips:
        stmt = stmt.where(
            literal_column(
                "question_translations.verification->'answerability'->>'verdict'"
            )
            == "translation_flip"
        )
    stmt = stmt.order_by(tt.c.updated_at).limit(limit)
    async with engine.connect() as conn:
        return [dict(r) for r in (await conn.execute(stmt)).mappings().all()]


def _split(joined: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    row = {k: v for k, v in joined.items() if not k.startswith("src_")}
    src = {k[4:]: v for k, v in joined.items() if k.startswith("src_")}
    src["id"] = str(src["id"])
    return row, src


def _draft(row: dict[str, Any]) -> TranslatedDraft:
    return TranslatedDraft(
        question=row["question"],
        correct_answer=row["correct_answer"],
        possible_answers=row.get("possible_answers") or None,
        correct_answer_key=row.get("correct_answer_key"),
        alternative_answers=list(row.get("alternative_answers") or []),
        explanation=row.get("explanation"),
        headline_answer=row.get("headline_answer"),
    )


def _draft_payload(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "question": row["question"],
        "possible_answers": row.get("possible_answers"),
        "correct_answer": row["correct_answer"],
        "alternative_answers": list(row.get("alternative_answers") or []),
        "explanation": row.get("explanation"),
        "headline_answer": row.get("headline_answer"),
    }


async def _write_verdict(
    engine: AsyncEngine,
    row: dict[str, Any],
    status: str,
    verification: dict[str, Any],
) -> None:
    tt, qt = question_translations_table, questions_table
    qid, language = row["question_id"], row["language"]
    if status == "approved":
        column = func.array_append(
            func.array_remove(qt.c.approved_languages, language), language
        )
    else:
        column = func.array_remove(qt.c.approved_languages, language)
    async with engine.begin() as conn:
        await conn.execute(
            update(tt)
            .where(tt.c.id == row["id"])
            .values(status=status, updated_at=func.now())
        )
        # JSONB column is outside the shared table surface — plain SQL.
        await conn.execute(
            text(
                "UPDATE question_translations SET verification = CAST(:v AS jsonb) "
                "WHERE id = :id"
            ),
            {"v": json.dumps(verification, ensure_ascii=False), "id": row["id"]},
        )
        await conn.execute(
            update(qt).where(qt.c.id == qid).values(approved_languages=column)
        )


async def verify_rows(
    engine: AsyncEngine,
    language: str,
    *,
    limit: int,
    concurrency: int = 4,
    judge_model: str | None = None,
    answerability_model: str | None = None,
    status: str = "pending",
    only_answerability_flips: bool = False,
    log: Callable[[str], None] = print,
) -> Counter:
    """Run the gate over up to ``limit`` rows in ``status``; returns status counts.

    ``status="rejected"`` + ``only_answerability_flips`` re-gates rows that were
    rejected solely by a weak answerability model, without re-translating
    (#168) — same outcome/persistence path as a pending row, just a different
    starting ``status`` filter.
    """
    rows = await _pending_rows(
        engine,
        language,
        limit,
        status=status,
        only_answerability_flips=only_answerability_flips,
    )
    default_selection = status == "pending" and not only_answerability_flips
    if not rows:
        log(
            "no pending rows"
            if default_selection
            else f"no {status} row(s)"
            + (" (answerability flips)" if only_answerability_flips else "")
            + " found"
        )
        return Counter()
    if not default_selection:
        log(
            f"{len(rows)} {status} row(s)"
            + (" (answerability flips)" if only_answerability_flips else "")
            + " selected"
        )
    judge = TranslationJudge(judge_model)
    checker = DeltaAnswerabilityChecker(answerability_model)
    regional = RegionalClassifier()
    sem = asyncio.Semaphore(concurrency)
    outcomes: Counter = Counter()

    async def one(joined: dict[str, Any]) -> None:
        row, src = _split(joined)
        async with sem:
            # The English text may have changed between ingest and verify.
            if row_source_hash(src) != row["source_hash"]:
                await _write_verdict(engine, row, "stale", {"stale": "source edited"})
                outcomes["stale"] += 1
                return
            source = source_question(src)
            draft = _draft(row)
            reasons = run_guards(source, draft, language)
            verification: dict[str, Any] = {
                "guards": {"ok": not reasons, "reasons": reasons},
                "verified_at": datetime.now(UTC).isoformat(),
            }
            if reasons:
                # Rejected regardless — LLM legs skipped to save calls.
                verification["skipped"] = "guards failed"
                await _write_verdict(engine, row, "rejected", verification)
                outcomes["rejected"] += 1
                return
            ans = await checker.check(source, draft, language)
            jr = await judge.judge(source_fields(src), _draft_payload(row), language)
            reg = await regional.classify(
                draft.question, language, draft.possible_answers
            )
            verification["answerability"] = ans.to_verification_json()
            verification["judge"] = jr.as_verification_json()
            verification.update(reg.as_verification_json())
            status = approval_status(
                guards_ok=True, answerable=ans.verdict != "translation_flip", judge=jr
            )
            if status == "approved" and ans.verdict == "unavailable":
                status = "pending"  # fail-closed: unjudged, not judged bad
            await _write_verdict(engine, row, status, verification)
            outcomes[status] += 1
            if sum(outcomes.values()) % 10 == 0:
                log(
                    f"  [{language}] {sum(outcomes.values())}/{len(rows)} {dict(outcomes)}"
                )

    await asyncio.gather(*(one(r) for r in rows))
    return outcomes
