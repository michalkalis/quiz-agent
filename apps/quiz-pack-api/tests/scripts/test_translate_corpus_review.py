"""``review-export`` selection, correction ingest, glossary (T16, DD3, locked 5).

Why it matters: the founder's review time is the scarcest input in the loop.
The export must put every critical and flagged row in front of them plus a
random sample of approvals — and nothing else. Corrections are append-only
because the category histogram IS the glossary loop; an in-place edit would
erase it. The glossary files are reviewed git artefacts: a report step that
wrote them would let unreviewed corrections re-enter the pipeline.
"""

from __future__ import annotations

import uuid
from pathlib import Path

import pytest
from scripts.translation_runner import review as rv
from sqlalchemy import text

from tests.scripts.conftest import delete_questions, make_question

GLOSSARY_DIR = (
    Path(__file__).resolve().parents[2]
    / "app"
    / "translation_verification"
    / "glossary"
)


def _row(qid: str, status: str, **verification) -> dict:
    return {
        "question_id": qid,
        "status": status,
        "question": "Q",
        "correct_answer": "A",
        "verification": verification,
    }


def test_review_export_selects_critical_flagged_and_random_sample() -> None:
    rows = [
        _row("crit-1", "rejected", guards={"ok": False, "reasons": ["numbers"]}),
        _row("flag-regional", "approved", regional={"flag": True, "reason": "US-only"}),
        _row("flag-major", "approved", judge={"findings": [{"severity": "major"}]}),
        *[_row(f"ok-{i}", "approved", judge={"findings": []}) for i in range(10)],
        _row("pending-1", "pending"),
    ]
    picked = rv.select_for_review(rows, sample=3, seed=7)
    buckets = {
        b: sorted(r["question_id"] for _, r in picked if _ == b) for b, _ in picked
    }
    assert buckets["critical"] == ["crit-1"]
    assert buckets["flagged"] == ["flag-major", "flag-regional"]
    assert len(buckets["sample"]) == 3 and all(
        q.startswith("ok-") for q in buckets["sample"]
    )
    assert "pending-1" not in {r["question_id"] for _, r in picked}
    # Seeded: the same seed picks the same sample, so a re-export is comparable.
    again = rv.select_for_review(rows, sample=3, seed=7)
    assert [r["question_id"] for _, r in again] == [r["question_id"] for _, r in picked]


def test_arm_item_carries_bucket_in_topic_not_in_a_new_key() -> None:
    item = rv.to_arm_item(
        "flagged", {**_row("q1", "approved"), "src_category": "history"}
    )
    assert item["topic"] == "history · flagged"
    assert set(item) <= {
        "id",
        "question",
        "possible_answers",
        "correct_answer",
        "alternative_answers",
        "explanation",
        "topic",
        "difficulty",
        "source_url",
    }


@pytest.mark.asyncio
async def test_correction_ingest_appends_row_with_mqm_category(
    translation_engine, question_store
) -> None:
    qid = uuid.uuid4()
    assert await question_store.add(make_question(qid)) is True
    try:
        async with translation_engine.begin() as conn:
            await conn.execute(
                text(
                    "INSERT INTO question_translations (id, question_id, language, status, "
                    "question, correct_answer, alternative_answers, model, prompt_version, "
                    "source_hash) VALUES (:id, :qid, 'sk', 'approved', 'Ktorá?', 'Taliansko', "
                    "'[]'::jsonb, 'test', 'v1', :h)"
                ),
                {"id": uuid.uuid4(), "qid": qid, "h": "b" * 64},
            )
        item = {
            "question_id": str(qid),
            "language": "sk",
            "field": "question",
            "before": "Ktorá?",
            "after": "Ktorá krajina?",
            "category": "calque",
            "note": "literal",
        }
        assert await rv.ingest_corrections(translation_engine, [item]) == 1
        assert (
            await rv.ingest_corrections(translation_engine, [item]) == 1
        )  # append, not upsert
        async with translation_engine.connect() as conn:
            n, translated = (
                await conn.execute(
                    text(
                        "SELECT count(*), min(t.question) FROM question_translation_corrections c "
                        "JOIN question_translations t ON t.id = c.translation_id "
                        "WHERE t.question_id = :qid AND c.category = 'calque'"
                    ),
                    {"qid": qid},
                )
            ).one()
        assert n == 2 and translated == "Ktorá?"  # the translation itself is untouched
        with pytest.raises(ValueError):
            await rv.ingest_corrections(translation_engine, [{**item, "category": ""}])
        hist = await rv.glossary_histogram(translation_engine, "sk")
        assert hist["calque"] >= 2
    finally:
        await delete_questions(translation_engine, [qid])


@pytest.mark.asyncio
async def test_glossary_histogram_is_report_only(translation_engine) -> None:
    before = {p.name: p.read_bytes() for p in GLOSSARY_DIR.glob("*.json")}
    assert before, "glossary files must exist (Session E)"
    await rv.glossary_histogram(translation_engine, "sk")
    await rv.glossary_histogram(translation_engine, "cs")
    assert {p.name: p.read_bytes() for p in GLOSSARY_DIR.glob("*.json")} == before
