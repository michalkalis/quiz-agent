"""Wire-compat contract for the typed PublicQuestion payload (arch review Group C).

iOS hand-mirrors the question dict the backend sends. When ``question_to_dict``
was converted from a hand-built dict to ``PublicQuestion``, the serialized JSON
had to keep *exactly* the legacy keys, casing and optionality for every question
type. The EXPECTED_WIRE dicts below are **literal captures** of the legacy
builder's output (captured 2026-07-20, pre-conversion) — they must never be
regenerated from the model, or the test becomes a tautology.

One key was deliberately *removed* from the capture since: ``headline_answer``
(#133 V8, 2026-07-30). It is the short answer gist the evaluator scores against,
so emitting it alongside the unanswered question handed the client the answer.
It is now structurally absent from ``PublicQuestion`` and pinned so by
``test_answer_fields_can_never_appear_in_payload``. Any *other* diff against
these captures is a wire break, not an improvement.
"""

import json
from datetime import datetime, timezone

from quiz_shared.models.question import PublicQuestion, Question

from app.serializers import question_to_dict
from app.api.deps import InputResponse, SessionResponse


FIXTURES = {
    "text_minimal": Question(
        id="q_text1",
        question="What is the capital of France?",
        type="text",
        correct_answer="Paris",
        topic="Geography",
        category="adults",
        difficulty="easy",
    ),
    "text_full": Question(
        id="q_text2",
        question="Why do cats purr?",
        type="text",
        correct_answer="Self-healing vibrations",
        headline_answer="healing vibrations",
        topic="Science",
        category="adults",
        difficulty="hard",
        source_url="https://example.com/purr",
        source_excerpt="Cats purr at healing frequencies.",
        explanation="Purring frequencies promote bone density.",
        age_appropriate="all",
        generation_metadata={"model": "gpt-9", "provider": "openai"},
    ),
    "text_multichoice": Question(
        id="q_mcq1",
        question="Which planet is largest?",
        type="text_multichoice",
        possible_answers={"a": "Mars", "b": "Jupiter", "c": "Venus"},
        correct_answer="Jupiter",
        topic="Science",
        category="adults",
        difficulty="medium",
    ),
    "audio": Question(
        id="q_aud1",
        question="Name the instrument you hear.",
        type="audio",
        correct_answer="Theremin",
        topic="Music",
        category="music",
        difficulty="medium",
        media_url="https://cdn.example.com/clip.opus",
        media_duration_seconds=12,
    ),
    "image": Question(
        id="q_img1",
        question="Which country is highlighted?",
        type="image",
        correct_answer="Portugal",
        topic="Geography",
        category="adults",
        difficulty="medium",
        media_url="https://cdn.example.com/map.png",
        image_subtype="blind_map",
    ),
    "video": Question(
        id="q_vid1",
        question="What movie is this scene from?",
        type="video",
        correct_answer="Jaws",
        topic="Movies",
        category="adults",
        difficulty="easy",
        media_url="https://cdn.example.com/scene.mp4",
        media_duration_seconds=8,
    ),
}

# Literal legacy output — see module docstring. Key facts encoded here:
# the 9 fixed keys are ALWAYS present (possible_answers/source_url/
# source_excerpt as null when unset); media_url / image_subtype / explanation /
# age_appropriate / generated_by are OMITTED (never null) when unset;
# correct_answer and headline_answer never appear at all.
EXPECTED_WIRE = {
    "text_minimal": {
        "id": "q_text1",
        "question": "What is the capital of France?",
        "type": "text",
        "possible_answers": None,
        "difficulty": "easy",
        "topic": "Geography",
        "category": "adults",
        "source_url": None,
        "source_excerpt": None,
    },
    "text_full": {
        "id": "q_text2",
        "question": "Why do cats purr?",
        "type": "text",
        "possible_answers": None,
        "difficulty": "hard",
        "topic": "Science",
        "category": "adults",
        "source_url": "https://example.com/purr",
        "source_excerpt": "Cats purr at healing frequencies.",
        "explanation": "Purring frequencies promote bone density.",
        "age_appropriate": "all",
        "generated_by": "gpt-9",
    },
    "text_multichoice": {
        "id": "q_mcq1",
        "question": "Which planet is largest?",
        "type": "text_multichoice",
        "possible_answers": {"a": "Mars", "b": "Jupiter", "c": "Venus"},
        "difficulty": "medium",
        "topic": "Science",
        "category": "adults",
        "source_url": None,
        "source_excerpt": None,
    },
    "audio": {
        "id": "q_aud1",
        "question": "Name the instrument you hear.",
        "type": "audio",
        "possible_answers": None,
        "difficulty": "medium",
        "topic": "Music",
        "category": "music",
        "source_url": None,
        "source_excerpt": None,
        "media_url": "https://cdn.example.com/clip.opus",
    },
    "image": {
        "id": "q_img1",
        "question": "Which country is highlighted?",
        "type": "image",
        "possible_answers": None,
        "difficulty": "medium",
        "topic": "Geography",
        "category": "adults",
        "source_url": None,
        "source_excerpt": None,
        "media_url": "https://cdn.example.com/map.png",
        "image_subtype": "blind_map",
    },
    "video": {
        "id": "q_vid1",
        "question": "What movie is this scene from?",
        "type": "video",
        "possible_answers": None,
        "difficulty": "easy",
        "topic": "Movies",
        "category": "adults",
        "source_url": None,
        "source_excerpt": None,
        "media_url": "https://cdn.example.com/scene.mp4",
    },
}


def test_wire_shape_unchanged_for_every_question_type():
    """The typed model must emit byte-for-byte the legacy dict per type."""
    assert set(FIXTURES) == set(EXPECTED_WIRE)
    for name, question in FIXTURES.items():
        assert question_to_dict(question) == EXPECTED_WIRE[name], name


def test_wire_shape_survives_json_mode_dump():
    """FastAPI serializes response models in JSON mode — must match too."""
    for name, question in FIXTURES.items():
        public = PublicQuestion.from_question(question)
        assert public.model_dump(mode="json") == EXPECTED_WIRE[name], name
        assert json.loads(public.model_dump_json()) == EXPECTED_WIRE[name], name


def test_optional_keys_are_absent_not_null():
    """iOS decodes media/extra keys by absence; emitting null would break it."""
    wire = question_to_dict(FIXTURES["text_minimal"])
    for key in (
        "media_url",
        "image_subtype",
        "explanation",
        "age_appropriate",
        "generated_by",
    ):
        assert key not in wire, f"{key} must be omitted, not present/null"


def test_answer_fields_can_never_appear_in_payload():
    """The answer must be structurally unable to leak to the client.

    Both spellings of "the answer" are guarded. ``headline_answer`` is not a
    softer variant: ``AnswerEvaluator`` scores against ``headline_answer or
    correct_answer``, so for an open question it *is* the answer — and it
    shipped with the still-unanswered question until #133 V8. ``text_full``
    below carries one, so this fails the moment the field returns.
    """
    for field in ("correct_answer", "headline_answer"):
        assert field not in PublicQuestion.model_fields, field
        for name, question in FIXTURES.items():
            assert field not in question_to_dict(question), f"{name}/{field}"
        # Even a poisoned input dict cannot smuggle the answer through validation.
        poisoned = {**EXPECTED_WIRE["text_full"], field: "healing vibrations"}
        dumped = PublicQuestion.model_validate(poisoned).model_dump()
        assert field not in dumped, field
    # Premise guard: text_full HAS a headline_answer, so its absence above is
    # the projection dropping it, not the fixture lacking one.
    assert FIXTURES["text_full"].headline_answer == "healing vibrations"


def test_legacy_dict_roundtrips_through_typed_field():
    """flow.py hands InputResponse a plain dict; coercion into the typed
    ``current_question`` field must not alter what iOS receives."""
    session = SessionResponse(
        session_id="s1",
        mode="single",
        phase="asking",
        max_questions=10,
        current_difficulty="easy",
        category=None,
        language="en",
        participants=[],
        expires_at=datetime(2026, 7, 20, 12, 0, tzinfo=timezone.utc),
        created_at=datetime(2026, 7, 20, 11, 0, tzinfo=timezone.utc),
    )
    for name, question in FIXTURES.items():
        resp = InputResponse(
            success=True,
            message="ok",
            session=session,
            current_question=question_to_dict(question),
        )
        payload = json.loads(resp.model_dump_json())
        assert payload["current_question"] == EXPECTED_WIRE[name], name
