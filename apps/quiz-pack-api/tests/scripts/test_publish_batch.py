"""`publish_batch.py` builds a payload the ratings API actually accepts (#154).

Two things could silently break the round rather than the script: the CLI
could stop reusing `build_page`'s blinding (two rounds blinded differently are
not comparable), or it could hand the API a question shape carrying arm/
provenance keys. Both are asserted against the REAL request model, so the test
fails the moment either contract moves.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from app.api.v1.ratings_schemas import CreateBatchRequest
from scripts.rating_page import build_page, publish_batch

ARM_A = [
    {
        "id": "orig-a1",
        "question": "Which planet has the shortest day?",
        "correct_answer": "Jupiter",
        "topic": "science",
        "difficulty": "medium",
        "source_url": "https://example.com/a1",
    },
    {
        "id": "orig-a2",
        "question": "What colour is a polar bear's skin?",
        "correct_answer": "b",
        "possible_answers": {"a": "White", "b": "Black"},
        "topic": "nature",
        "source_url": "https://example.com/a2",
    },
]
ARM_B = [
    {
        "id": "orig-b1",
        "question": "Which sea has no coastline?",
        "correct_answer": "The Sargasso Sea",
        "topic": "geography",
        "source_url": "https://example.com/b1",
    },
]


@pytest.fixture
def arm_files(tmp_path: Path) -> list[str]:
    specs = []
    for name, rows in (("alpha", ARM_A), ("beta", ARM_B)):
        path = tmp_path / f"{name}.json"
        path.write_text(json.dumps(rows), encoding="utf-8")
        specs.append(f"{name}={path}")
    return specs


def test_uses_build_pages_own_blinding(arm_files: list[str]) -> None:
    """Imported, not reimplemented — a copy would drift between the two modes."""
    assert publish_batch.select_and_blind is build_page.select_and_blind

    questions, mapping = build_page.select_and_blind(arm_files, seed=154, dedupe=False)
    assert [q["id"] for q in questions] == ["q01", "q02", "q03"]
    assert {m["arm"] for m in mapping.values()} == {"alpha", "beta"}


def test_payload_is_accepted_and_carries_no_arm(arm_files: list[str]) -> None:
    questions, mapping = build_page.select_and_blind(arm_files, seed=154, dedupe=False)
    payload = {
        "title": "Kolo 3",
        "questions": [publish_batch.to_api_question(q) for q in questions],
        "mapping": mapping,
    }

    parsed = CreateBatchRequest.model_validate(payload)
    assert len(parsed.questions) == 3

    # Whatever the arms were called, none of it may sit in the rater payload.
    visible = json.dumps([q.model_dump() for q in parsed.questions])
    for leak in ("alpha", "beta", "orig-a1", "orig-b1"):
        assert leak not in visible
    # …while the server-side mapping still unblinds every question.
    assert set(mapping) == {q.qid for q in parsed.questions}


def test_meta_carries_the_card_fields(arm_files: list[str]) -> None:
    """The page renders options/topic/source from `meta`; dropping them would
    quietly turn an MCQ card into a bare question."""
    questions, _ = build_page.select_and_blind(arm_files, seed=154, dedupe=False)
    mcq = next(
        publish_batch.to_api_question(q)
        for q in questions
        if q["question"].startswith("What colour")
    )
    assert mcq["answer"] == "b"
    assert mcq["meta"]["options"] == {"a": "White", "b": "Black"}
    assert mcq["meta"]["topic"] == "nature"
    assert mcq["meta"]["source_url"] == "https://example.com/a2"


def test_dedupe_by_fact_flag_reaches_the_selection(tmp_path: Path) -> None:
    """Two arms building on the same source must collapse to one card."""
    same_fact = [{"id": "x", "question": "Q", "correct_answer": "a",
                  "source_url": "https://example.com/shared"}]
    specs = []
    for name in ("alpha", "beta"):
        path = tmp_path / f"{name}.json"
        path.write_text(json.dumps(same_fact), encoding="utf-8")
        specs.append(f"{name}={path}")

    kept, mapping = build_page.select_and_blind(specs, seed=1, dedupe=True)
    assert len(kept) == 1 and len(mapping) == 1
