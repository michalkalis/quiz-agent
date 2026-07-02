"""Unit tests for ExpiryClassifier (issue #76 F-3b task 2).

Why these scenarios: the classifier is the first writer of a question's
temporal freshness, and the founder reviews "why 14 days?" per question from
its logs. It must (a) tell a `current` answer (a living person's *current* age,
tied to a moving "now") apart from an `evergreen` one (a dated historical fact),
(b) drive the TTL off the shared `CONTENT_CLASS_TTL` map — never a hardcoded
number — so retuning the map retunes the pipeline, and (c) fail safe on every
error path (unavailable model, unparseable response, thrown exception, count
mismatch) because a broken classifier must never block generation. Each test
below pins one of those guarantees.
"""

from __future__ import annotations

import json

import pytest

from app.generation.expiry_classifier import (
    CONTENT_CLASS_TTL,
    Classification,
    ExpiryClassifier,
)
from quiz_shared.models.question import Question


def _question(text: str, answer: str = "answer") -> Question:
    return Question(
        id=f"q_{abs(hash(text)) % 10_000}",
        question=text,
        correct_answer=answer,
        topic="General",
        category="entertainment",
        difficulty="medium",
    )


def _classifier_with(response: str) -> ExpiryClassifier:
    """Classifier whose single LLM boundary returns canned text.

    Stubs ``_complete`` (the issue #53 factory seam) so the batching + JSON
    parsing + decision logic runs without a live model.
    """
    clf = ExpiryClassifier(api_key="test-key")

    async def _fake_complete(prompt: str) -> str:
        return response

    clf._complete = _fake_complete  # inject, bypass the live client
    return clf


# The two canonical F-3b examples in one batch: a "who currently / current age"
# question (moves with the calendar → current) and a dated historical fact
# (fixed forever → evergreen). Batched because the classifier makes exactly one
# LLM call per run.
_SINGER = "In June 2026, which singer celebrated her 50th birthday?"
_FILM = "Which film won Best Picture in 1994?"

_BATCH_RESPONSE = json.dumps(
    {
        "classifications": [
            {
                "index": 1,
                "content_class": "current",
                "rationale": "Tied to a birthday in the current month; the "
                "'who' framing tracks a moving present.",
            },
            {
                "index": 2,
                "content_class": "evergreen",
                "rationale": "A dated historical award result that never changes.",
            },
        ]
    }
)


@pytest.mark.asyncio
async def test_current_question_classified_current_with_map_ttl() -> None:
    """The singer/birthday question is `current`; its TTL comes from the shared
    map (14 days today) and it carries a non-empty rationale for founder review.

    The TTL is asserted *via* `CONTENT_CLASS_TTL`, not a literal `14 days`, so
    retuning the map moves this assertion with it — the whole point of keeping
    TTLs in one config spot.
    """
    clf = _classifier_with(_BATCH_RESPONSE)

    result = await clf.classify([_question(_SINGER), _question(_FILM)])

    assert result[0] is not None
    assert result[0].content_class == "current"
    # TTL read from the config map (not hardcoded); `current` must be a
    # finite, expiring class.
    assert CONTENT_CLASS_TTL[result[0].content_class] is not None
    assert result[0].rationale  # non-empty rationale for the run log


@pytest.mark.asyncio
async def test_evergreen_question_classified_evergreen_no_ttl() -> None:
    """The 1994 Best Picture question is `evergreen`; the map yields no TTL, so
    the stamping loop will leave `expires_at` unset (a fact that never expires).
    """
    clf = _classifier_with(_BATCH_RESPONSE)

    result = await clf.classify([_question(_SINGER), _question(_FILM)])

    assert result[1] is not None
    assert result[1].content_class == "evergreen"
    # Evergreen carries no expiry in the shared map.
    assert CONTENT_CLASS_TTL[result[1].content_class] is None


@pytest.mark.asyncio
async def test_classify_reads_question_and_answer_only() -> None:
    """Type-agnostic contract: the batched prompt contains each question's text
    and its correct answer and nothing type-specific, so image/kids/themed
    questions reuse the classifier unchanged. Pins that both fields are sent."""
    clf = ExpiryClassifier(api_key="test-key")
    captured: dict[str, str] = {}

    async def _capture(prompt: str) -> str:
        captured["prompt"] = prompt
        return _BATCH_RESPONSE

    clf._complete = _capture
    await clf.classify(
        [
            _question("Who is the current UN Secretary-General?", "António Guterres"),
            _question(_FILM, "Forrest Gump"),
        ]
    )

    assert "Who is the current UN Secretary-General?" in captured["prompt"]
    assert "António Guterres" in captured["prompt"]
    assert "Forrest Gump" in captured["prompt"]


@pytest.mark.asyncio
async def test_empty_input_makes_no_call() -> None:
    """No questions → no LLM call, empty result (guards the batched call)."""
    clf = ExpiryClassifier(api_key="test-key")

    async def _boom(prompt: str) -> str:
        raise AssertionError("must not call the model for an empty batch")

    clf._complete = _boom
    assert await clf.classify([]) == []


@pytest.mark.asyncio
async def test_unavailable_model_fails_safe_to_none() -> None:
    """No API key under the direct gateway → model never inits → every question
    unclassified (all `None`), never raises. Expiry stays unset downstream."""
    clf = ExpiryClassifier(api_key=None)
    clf.api_key = None  # neutralise any ambient OPENAI_API_KEY

    result = await clf.classify([_question(_SINGER), _question(_FILM)])

    assert result == [None, None]


@pytest.mark.asyncio
async def test_llm_exception_fails_safe_and_warns(
    caplog: pytest.LogCaptureFixture,
) -> None:
    """A thrown LLM error must fail safe to all-`None` + a warning, never
    propagate into the generation pipeline."""
    clf = ExpiryClassifier(api_key="test-key")

    async def _raise(prompt: str) -> str:
        raise RuntimeError("model exploded")

    clf._complete = _raise
    with caplog.at_level("WARNING"):
        result = await clf.classify([_question(_SINGER)])

    assert result == [None]
    assert any("ExpiryClassifier" in r.message for r in caplog.records)


@pytest.mark.asyncio
async def test_unparseable_response_fails_safe(
    caplog: pytest.LogCaptureFixture,
) -> None:
    """A response with no JSON object leaves all questions unclassified + warns."""
    clf = _classifier_with("Sorry, I can't produce JSON right now.")

    with caplog.at_level("WARNING"):
        result = await clf.classify([_question(_SINGER)])

    assert result == [None]
    assert any("ExpiryClassifier" in r.message for r in caplog.records)


@pytest.mark.asyncio
async def test_count_mismatch_leaves_missing_unclassified(
    caplog: pytest.LogCaptureFixture,
) -> None:
    """The model returns only one of two classifications: the covered question
    is classified, the missing one stays `None`, and the mismatch is a warning
    (not a failure) — a partial run must never block generation."""
    partial = json.dumps(
        {
            "classifications": [
                {"index": 1, "content_class": "current", "rationale": "recent"}
            ]
        }
    )
    clf = _classifier_with(partial)

    with caplog.at_level("WARNING"):
        result = await clf.classify([_question(_SINGER), _question(_FILM)])

    assert result[0] == Classification(content_class="current", rationale="recent")
    assert result[1] is None
    assert any("count mismatch" in r.message for r in caplog.records)


@pytest.mark.asyncio
async def test_unknown_class_is_ignored() -> None:
    """An out-of-vocabulary content_class is dropped to `None` (not persisted as
    a bogus class) so a hallucinated label can't produce a garbage freshness_tag.
    """
    bogus = json.dumps(
        {
            "classifications": [
                {"index": 1, "content_class": "spicy", "rationale": "x"}
            ]
        }
    )
    clf = _classifier_with(bogus)

    result = await clf.classify([_question(_SINGER)])

    assert result == [None]
