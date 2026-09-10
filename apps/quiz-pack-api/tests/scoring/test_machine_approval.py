"""#177 machine-approval predicate — every reject reason is pinned here.

Why these scenarios: `approved` is what an App Store client is served. The
founder's 2026-09-10 rule lets the *machine* produce that state, so the only
thing standing between an unchecked row and every paying client is this
predicate being **fail-closed**. Each test below encodes one way a row could
sneak through if the predicate ever started treating absent evidence as clean:
missing source, non-EN text, pack-scoped row, hand-curated row with no
provenance, unverified/low-confidence verdict, the evergreen tier (no web
fact-check ever ran — founder decision pending), a persisted shadow finding,
and a pre-#177 batch whose craft findings must be recomputed rather than
assumed absent.
"""

from __future__ import annotations

from typing import Any

import pytest
from app.orchestrator.stages.verification import DEFAULT_MIN_CONFIDENCE
from app.scoring.machine_approval import (
    CRAFT_FLAG_KEY,
    GATE_VERSION,
    MIN_VERIFICATION_SCORE,
    UNDATED_FLAG_KEY,
    VETO_FLAG_KEY,
    machine_approval_block_reason,
    stamp_review_flag,
    tf_imbalance_excess_ids,
)
from quiz_shared.models.question import Question

_CLEAN_EXTRA: dict[str, Any] = {
    "verified": True,
    "verification_score": 0.9,
    "factcheck_tier": "web",
}


def _q(**overrides: Any) -> Question:
    """A row that cleared every gate: the only shape allowed to return None."""
    base: dict[str, Any] = {
        "id": "q_clean",
        "question": "Which planet in our solar system spins fastest on its axis?",
        "correct_answer": "Jupiter",
        "topic": "Science",
        "category": "science",
        "difficulty": "medium",
        "language": "en",
        "source_url": "https://en.wikipedia.org/wiki/Jupiter",
        "generation_metadata": {"extra": dict(_CLEAN_EXTRA)},
    }
    base.update(overrides)
    return Question(**base)


def test_clean_english_row_is_machine_approvable() -> None:
    """The positive case: without it, a fail-closed predicate could block
    everything and the feature would be silently dead."""
    assert machine_approval_block_reason(_q()) is None


@pytest.mark.parametrize(
    "overrides,expected_fragment",
    [
        ({"language": None}, "language="),
        ({"language": "sk"}, "language="),
        ({"pack_id": "f0e1d2c3"}, "pack_scoped"),
        ({"source_url": None}, "no_source_url"),
        ({"source_url": "   "}, "no_source_url"),
        ({"generation_metadata": None}, "no_provenance"),
    ],
)
def test_structural_fields_block(
    overrides: dict[str, Any], expected_fragment: str
) -> None:
    """Source mandatory (founder 2026-09-09), EN-only gates, pack rows and
    hand-curated rows can never be machine-approved."""
    reason = machine_approval_block_reason(_q(**overrides))
    assert reason is not None and expected_fragment in reason


@pytest.mark.parametrize(
    "extra,expected_fragment",
    [
        ({}, "verified="),
        ({"verified": False}, "verified="),
        ({"verified": True}, "verification_score="),
        (
            {"verified": True, "verification_score": "0.9"},
            "verification_score=",
        ),
        (
            {"verified": True, "verification_score": 0.4, "factcheck_tier": "web"},
            "verification_score=",
        ),
        (
            {"verified": True, "verification_score": 0.9},
            "factcheck_tier=",
        ),
        (
            {
                "verified": True,
                "verification_score": 0.9,
                "factcheck_tier": "evergreen",
            },
            "factcheck_tier=",
        ),
        (
            {**_CLEAN_EXTRA, "held_for_review": True},
            "held_for_review",
        ),
    ],
)
def test_verification_evidence_blocks(
    extra: dict[str, Any], expected_fragment: str
) -> None:
    """Absent, unparsable or below-bar verification evidence must read as
    "unknown", never as "fine" — including the evergreen tier, which never ran
    a web fact-check at all (founder decision pending, #177)."""
    reason = machine_approval_block_reason(_q(generation_metadata={"extra": extra}))
    assert reason is not None and expected_fragment in reason


@pytest.mark.parametrize("key", [CRAFT_FLAG_KEY, UNDATED_FLAG_KEY, VETO_FLAG_KEY])
def test_persisted_shadow_flag_blocks(key: str) -> None:
    """A gate that flagged-but-kept the row (#177 T1) is a finding: the whole
    point of the rule is "zero findings → approved"."""
    q = _q()
    stamp_review_flag(q, key, "some_reason")
    reason = machine_approval_block_reason(q)
    assert reason == f"{key}=some_reason"


def test_craft_finding_is_recomputed_for_a_pre_177_batch() -> None:
    """Batches generated before the flag keys existed carry no craft_flag —
    absence must trigger a recompute from the row, not a free pass."""
    q = _q(
        question="Which large gas planet is nicknamed the gas giant Jupiter?",
        correct_answer="Jupiter",
    )
    reason = machine_approval_block_reason(q)
    assert reason is not None and reason.startswith(f"{CRAFT_FLAG_KEY}=")


def test_undated_record_is_recomputed_for_a_pre_177_batch() -> None:
    """Same for the undated-record heuristic: it is shadow-only in the pipeline
    (it never drops), so import is the first place it can change an outcome."""
    q = _q(
        question="Which country was the first ever to ban commercial whaling?",
        correct_answer="Norway",
    )
    reason = machine_approval_block_reason(q)
    assert reason is not None and reason.startswith(f"{UNDATED_FLAG_KEY}=")


def test_true_false_key_imbalance_blocks_the_excess_rows() -> None:
    """T/F key balance is a batch property — an all-True import is a quiz
    design defect even though every single row looks clean on its own."""
    rows = [
        _q(
            id=f"q_tf_{i}",
            question=f"True or false: fact number {i} about Jupiter is real?",
            correct_answer="True",
            possible_answers={"a": "True", "b": "False"},
        )
        for i in range(5)
    ]
    excess = tf_imbalance_excess_ids(rows)
    assert excess, "an all-True batch must shed rows"
    blocked = [
        r.id for r in rows if machine_approval_block_reason(r, excess) is not None
    ]
    assert set(excess) <= set(blocked)


def test_gate_version_is_machine_prefixed() -> None:
    """`reviewed_by LIKE 'machine:%'` is how SQL (and CONTEXT.md) tells a
    machine approval from the founder's — the prefix is load-bearing."""
    assert GATE_VERSION.startswith("machine:")


def test_confidence_bar_matches_the_verification_stage() -> None:
    """The predicate re-states the pipeline's confidence floor instead of
    importing the LLM-heavy stage module; if the stage ever moves its bar, this
    fails loudly rather than silently approving weaker evidence."""
    assert MIN_VERIFICATION_SCORE == DEFAULT_MIN_CONFIDENCE
