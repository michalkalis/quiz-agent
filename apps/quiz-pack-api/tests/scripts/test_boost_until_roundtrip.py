"""#195 — `boost_until` survives every hop from dry-run JSON to the live read.

Why: the fresh-question batch is generated + classified into JSON, then
imported separately. Every seam here is mapped field-by-field on purpose, so a
seam that forgets the new column silently ships the batch UNBOOSTED — no error,
just a feature that never happens. Each test pins one hop:
classify script → JSON → importer → INSERT dict → ORM read → pgvector read.
"""

from __future__ import annotations

import asyncio
import json
from datetime import date, datetime, timezone
from pathlib import Path

from app.db.models.question import question_to_row, row_to_question
from app.generation.topicality_classifier import Topicality
from quiz_shared.database.pgvector_client import _question_to_row_dict, _row_to_question
from quiz_shared.models.question import Question
from scripts.classify_topicality import classify_questions
from scripts.import_questions_json import _load_questions
from scripts.migrate_pending_to_postgres import _row_to_insert_dict

UNTIL = datetime(2027, 3, 15, tzinfo=timezone.utc)


def _row(qid: str, **extra) -> dict:
    return {
        "id": qid,
        "question": f"stub question {qid}",
        "correct_answer": "answer",
        "topic": "General",
        "category": "entertainment",
        "difficulty": "medium",
        **extra,
    }


class _StubClassifier:
    def __init__(self) -> None:
        self.batches: list[int] = []

    async def classify(self, questions, today=None):
        self.batches.append(len(questions))
        return [Topicality("year", date(2026, 10, 1), "award") for _ in questions]


def test_classify_script_batches_and_output_reimports_with_boost(tmp_path: Path) -> None:
    """The script output is what the importer reads back — the boost and the
    reviewable verdict must both be there after the JSON hop."""
    questions = [Question.model_validate(_row(f"q{i}")) for i in range(30)]
    clf = _StubClassifier()
    asyncio.run(classify_questions(questions, clf, batch_size=25))  # type: ignore[arg-type]
    assert clf.batches == [25, 5]

    out = tmp_path / "boosted.json"
    out.write_text(json.dumps([q.model_dump(mode="json") for q in questions]))
    loaded = _load_questions([out], "pending_review")
    assert all(q.boost_until is not None for q in loaded)
    assert loaded[0].generation_metadata.extra["topicality"]["tier"] == "year"


def test_importer_and_orm_seam_keep_boost_until(tmp_path: Path) -> None:
    path = tmp_path / "batch.json"
    path.write_text(json.dumps([_row("q_fresh", boost_until=UNTIL.isoformat())]))
    (q,) = _load_questions([path], "pending_review")
    assert q.boost_until == UNTIL

    row = question_to_row(q.model_copy(update={"id": "7c9e6679-7425-40de-944b-e07fc1f90ae7"}))
    assert _row_to_insert_dict(row)["boost_until"] == UNTIL
    assert row_to_question(row).boost_until == UNTIL


def test_pgvector_read_path_keeps_boost_until() -> None:
    """quiz-agent reads through `PgvectorQuestionStore` — the weighted pick
    only sees a boost this mapping carries."""
    q = Question.model_validate(_row("7c9e6679-7425-40de-944b-e07fc1f90ae7", boost_until=UNTIL))
    as_row = _question_to_row_dict(q, embedding=None)
    assert as_row["boost_until"] == UNTIL
    assert _row_to_question(as_row).boost_until == UNTIL
    legacy = {k: v for k, v in as_row.items() if k != "boost_until"}
    assert _row_to_question(legacy).boost_until is None
