"""``submit`` and ``ingest`` for ``translate_corpus.py`` (T15, DD7, DD9).

Transport follows the DD8 verdict: the per-language model is Gemini 2.5 Pro
on the API route (synchronous — the T3 finding: no usable OpenRouter batch for
Gemini), and under ``LLM_GATEWAY=session`` the same runner translates with
Opus on the Claude Code subscription (#169), recording the model actually used
in the row's provenance so the two stay distinguishable. The OpenRouter batch
adapter is deliberately not wired here: neither chosen route uses it.

The prompt is the arm-test prompt the founder rated (``translate_arms_backends``)
plus ``headline_answer``, which the serve record carries and the arm test did
not show raters. ``prompt_version`` names that variant.

``submit`` only writes the job JSONL; ``ingest`` is the only writer of DB rows,
and it writes ``pending`` rows — approval is ``verify``'s job.
"""

from __future__ import annotations

import asyncio
import json
import uuid
from collections.abc import Callable, Sequence
from datetime import UTC, datetime
from decimal import Decimal
from typing import Any

from langchain_core.messages import HumanMessage, SystemMessage
from quiz_shared.database.pgvector_client import questions_table
from quiz_shared.llm import factory
from scripts.translate_arms_backends import (
    _SYSTEM,
    LANGUAGE_NAMES,
    MAX_TOKENS,
    PAYLOAD_FIELDS,
    parse_translation,
)
from sqlalchemy import func, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncEngine

from .workset import Job, correct_answer_key, row_source_hash, source_fields

PROMPT_VERSION = "corpus-v1"
#: DD8 verdict, both languages (founder 2026-09-04 sk, 2026-09-06 cs).
TRANSLATION_MODEL: dict[str, str] = {
    "sk": "google/gemini-2.5-pro",
    "cs": "google/gemini-2.5-pro",
}
#: Order-of-magnitude per-request estimate for the API route (arm-test scale).
EST_USD_PER_REQUEST = 0.003

_INSTRUCTIONS = """Translate this quiz question into {language}.

Rules:
- Return ONLY a JSON object with these keys: question, possible_answers, correct_answer, alternative_answers, explanation, headline_answer.
- Keep the structure identical: if possible_answers is an object, return an object with the SAME keys; if it is null, return null. If headline_answer is null, return null.
- correct_answer must stay the answer to the translated question, and for a multiple-choice question it must be the translated text of the same option.
- alternative_answers are extra spellings/forms a player might say out loud; return natural {language} variants (it may be a different number of entries than the source).
- Translate proper nouns only where {language} has an established form; otherwise keep the original.
- Never add, drop or change facts, numbers, dates or units.
- No commentary, no markdown fences.

Question JSON:
{payload}"""


def build_prompt(row: dict[str, Any], language: str) -> str:
    return _INSTRUCTIONS.format(
        language=LANGUAGE_NAMES[language],
        payload=json.dumps(source_fields(row), ensure_ascii=False, indent=2),
    )


def parse_payload(text: str) -> dict[str, Any]:
    """The arm parser (fails loud on a missing field) + the headline leg."""
    data = parse_translation(text)
    return {
        **{k: data[k] for k in PAYLOAD_FIELDS},
        "headline_answer": data.get("headline_answer"),
    }


def resolve_transport(model: str) -> tuple[str, str]:
    """``(transport, model_actually_used)`` for provenance (DD3)."""
    if factory.gateway() == factory.SESSION:
        return "session", factory.session_model_for(model)
    return "sync", model


async def translate_rows(
    rows: Sequence[dict[str, Any]],
    language: str,
    *,
    model: str,
    job: Job,
    concurrency: int = 4,
    log: Callable[[str], None] = print,
) -> list[str]:
    """Translate ``rows`` and append one ``translation``/``failure`` line each.

    Returns the failed ids. Progress is durable per row, so a killed run
    resumes from ``job.done_qids()``.
    """
    transport, used = resolve_transport(model)
    chat = factory.chat_openai(model, max_tokens=MAX_TOKENS)
    sem = asyncio.Semaphore(concurrency)
    failures: list[str] = []
    done = 0

    async def one(row: dict[str, Any]) -> None:
        nonlocal done
        qid = str(row["id"])
        async with sem:
            try:
                response = await chat.ainvoke(
                    [
                        SystemMessage(content=_SYSTEM),
                        HumanMessage(content=build_prompt(row, language)),
                    ]
                )
                payload = parse_payload(factory.message_text(response))
            except Exception as exc:  # the call boundary: record, never approve
                failures.append(qid)
                job.append({"kind": "failure", "qid": qid, "error": str(exc)[:500]})
                return
        job.append(
            {
                "kind": "translation",
                "qid": qid,
                "language": language,
                "payload": payload,
                "model": used,
                "transport": transport,
                "prompt_version": PROMPT_VERSION,
                "source_hash": row_source_hash(row),
                "correct_answer_key": correct_answer_key(row),
                "translated_at": datetime.now(UTC).isoformat(),
            }
        )
        done += 1
        if done % 10 == 0:
            log(f"  [{language}/{transport}] {done}/{len(rows)}")

    await asyncio.gather(*(one(r) for r in rows))
    return failures


async def record_cost(
    job: Job, *, transport: str, n_requests: int, usage_before: float | None
) -> None:
    """DD9: per-batch spend line. Session = 0 by construction (subscription);
    API = OpenRouter credits delta, ``None`` when it cannot be read."""
    if transport == "session":
        usd: float | None = 0.0
    else:
        from app.cost_tracking import fetch_openrouter_usage

        after = await fetch_openrouter_usage()
        usd = None
        if usage_before is not None and after is not None:
            usd = max(0.0, after - usage_before)
    job.append({"kind": "cost", "usd": usd, "n_requests": n_requests})


def _per_question_cents(job: Job, n: int) -> Decimal | None:
    usd = job.cost_usd()
    if usd is None or n <= 0:
        return None
    return (Decimal(str(usd)) * 100 / n).quantize(Decimal("0.0001"))


async def ingest_job(
    engine: AsyncEngine, job: Job, *, log: Callable[[str], None] = print
) -> int:
    """Write every not-yet-ingested translation as a ``pending`` row.

    Upsert on ``(question_id, language)``: a re-translation (stale row) drops
    the row back to ``pending`` with a fresh payload, and the language leaves
    ``approved_languages`` in the same transaction (DD1: column ⇔ table).
    ``verification`` is reset — the old verdict was about the old text.
    """
    from app.db.models.translation import QuestionTranslation

    translations = job.translations()
    ingested = job.done_qids("ingested")
    todo = [t for t in translations if str(t["qid"]) not in ingested]
    if not todo:
        log("nothing to ingest")
        return 0
    cents = _per_question_cents(job, len(translations))
    table = QuestionTranslation.__table__
    count = 0
    for t in todo:
        p = t["payload"]
        qid = uuid.UUID(str(t["qid"]))
        values = {
            "id": uuid.uuid4(),
            "question_id": qid,
            "language": t["language"],
            "status": "pending",
            "question": p["question"],
            "possible_answers": p.get("possible_answers") or None,
            "explanation": p.get("explanation"),
            "headline_answer": p.get("headline_answer"),
            "correct_answer": _answer_text(p, t.get("correct_answer_key")),
            "correct_answer_key": t.get("correct_answer_key"),
            "alternative_answers": list(p.get("alternative_answers") or []),
            "model": t["model"],
            "prompt_version": t["prompt_version"],
            "batch_id": job.id,
            "cost_cents": cents,
            "source_hash": t["source_hash"],
            "verification": {},
        }
        stmt = pg_insert(table).values(**values)
        update_cols = {
            k: getattr(stmt.excluded, k)
            for k in values
            if k not in ("id", "question_id", "language")
        }
        update_cols["updated_at"] = func.now()
        stmt = stmt.on_conflict_do_update(
            index_elements=["question_id", "language"], set_=update_cols
        )
        async with engine.begin() as conn:
            await conn.execute(stmt)
            await conn.execute(
                update(questions_table)
                .where(questions_table.c.id == qid)
                .values(
                    approved_languages=func.array_remove(
                        questions_table.c.approved_languages, t["language"]
                    )
                )
            )
        job.append({"kind": "ingested", "qid": str(qid)})
        count += 1
    log(f"ingested {count} pending row(s) from job {job.id}")
    return count


def _answer_text(payload: dict[str, Any], key: str | None = None) -> str:
    """MCQ: the display answer is the translated option under ``key`` (the
    serve record never translates it twice); open: the translated answer."""
    options = payload.get("possible_answers") or {}
    if key and options.get(key):
        return str(options[key])
    answer = payload.get("correct_answer")
    if isinstance(answer, list):
        answer = answer[0] if answer else ""
    return str(answer or "")
