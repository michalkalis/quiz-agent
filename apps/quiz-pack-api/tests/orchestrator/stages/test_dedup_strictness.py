"""#170 D6 — per-category strictness + answer cap inside DedupStage (170.8 / 170.9).

Why these scenarios:
- Locked 6a: `entertainment` tolerates a looser dedup than the evergreen
  corpus. The profile must (a) change nothing when empty (flag OFF = today),
  (b) move the cosine threshold for ONE category only, (c) never let a
  relaxed category loosen a stricter neighbour in a pairwise in-batch check,
  and (d) count answer-cap drops separately from cosine drops so the
  quality-guard metrics stay attributable.
- A cap that is ON without a corpus counter would silently count only the
  current batch — that must be a construction error, not a quiet under-cap.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from app.orchestrator.stages.dedup import DEFAULT_COSINE_THRESHOLD, DedupStage
from app.orchestrator.stages.strictness import Strictness, parse_strictness

from tests.orchestrator.stages.test_dedup import (
    _FakeQuestionStore,
    _make_ctx,
    _RecordingSink,
    _stub_question,
)


@pytest.fixture
def empty_gold_standard(tmp_path: Path) -> Path:
    p = tmp_path / "gold_standard.json"
    p.write_text("[]", encoding="utf-8")
    return p


class _CountingAnswers:
    """`AsyncAnswerCounter` double: canned corpus counts per (lang, cat, key)."""

    def __init__(self, counts: dict[tuple[str, str, str], int] | None = None) -> None:
        self.counts = counts or {}
        self.calls: list[tuple[str, str, str]] = []

    async def count_answer_key(
        self, language: str, category: str, answer_key: str
    ) -> int:
        self.calls.append((language, category, answer_key))
        return self.counts.get((language, category, answer_key), 0)


@pytest.mark.asyncio
async def test_empty_profile_is_todays_behaviour(empty_gold_standard: Path) -> None:
    near = _stub_question(9, "near duplicate")
    store = _FakeQuestionStore({"stub question 0": [(near, 0.90)]})
    stage = DedupStage(store, empty_gold_standard, strictness=Strictness(profiles={}))
    result = await stage.run(_make_ctx([_stub_question(0)]), sink=_RecordingSink())
    assert result.info["kept"] == 0 and result.info["dropped"] == 1
    assert store.find_calls == [("stub question 0", DEFAULT_COSINE_THRESHOLD)]
    assert result.info["answer_cap"] == 0
    assert result.info["drop_reasons"]["cosine"] == 1


@pytest.mark.asyncio
async def test_relaxed_cosine_applies_to_its_category_only(
    empty_gold_standard: Path,
) -> None:
    """A 0.90 match passes in entertainment (threshold 0.92) and drops in general (0.85)."""
    near = _stub_question(9, "near duplicate")
    store = _FakeQuestionStore(
        {"stub question 0": [(near, 0.90)], "stub question 1": [(near, 0.90)]}
    )
    strictness = Strictness(profiles=parse_strictness("entertainment=cosine:0.92"))
    stage = DedupStage(store, empty_gold_standard, strictness=strictness)
    ctx = _make_ctx(
        [
            _stub_question(0, category="entertainment"),
            _stub_question(1, category="general"),
        ]
    )
    result = await stage.run(ctx, sink=_RecordingSink())
    assert [q.id for q in ctx.questions] == ["q_0"]
    assert result.info["drop_reasons"]["cosine"] == 1
    assert store.find_calls == [("stub question 0", 0.92), ("stub question 1", 0.85)]


@pytest.mark.asyncio
async def test_cross_category_in_batch_pair_uses_the_stricter_profile(
    empty_gold_standard: Path,
) -> None:
    """Relaxing entertainment's in-batch Jaccard to 0.95 must not let an
    entertainment paraphrase of a *general* batchmate through: the pair is
    judged at min(0.95, 0.60) = 0.60. (fact is relaxed too so the same-fact
    content branch, which shares the answer token, does not mask the in-batch
    verdict — a real profile relaxes every lever together, D6.)"""
    strictness = Strictness(
        profiles=parse_strictness("entertainment=in_batch:0.95,fact:0.95")
    )
    stage = DedupStage(_FakeQuestionStore(), empty_gold_standard, strictness=strictness)
    text_a = "which river runs through the city of vienna"
    text_b = "which river runs through the city of vienna today"
    a = _stub_question(0, text_a, category="general")
    b = _stub_question(1, text_b, category="entertainment")
    result = await stage.run(_make_ctx([a, b]), sink=_RecordingSink())
    assert result.info["kept"] == 1 and result.info["drop_reasons"]["in_batch"] == 1

    # Same pair inside ONE relaxed category → judged at 0.95 → both survive.
    a2 = _stub_question(2, text_a, category="entertainment")
    b2 = _stub_question(3, text_b, category="entertainment")
    result2 = await stage.run(_make_ctx([a2, b2]), sink=_RecordingSink())
    assert result2.info["kept"] == 2


@pytest.mark.asyncio
async def test_answer_cap_counts_corpus_plus_batch_per_category(
    empty_gold_standard: Path,
) -> None:
    """cap 3 (default): with 2 corpus rows already answering "paris" in
    general, the first batch candidate is #3 and passes, the second is #4 and
    drops with its OWN counter; entertainment (cap 6) admits both of its own."""
    counter = _CountingAnswers({("en", "general", "paris"): 2})
    strictness = Strictness(
        profiles=parse_strictness("entertainment=cap:6"), answer_cap=True
    )
    stage = DedupStage(
        _FakeQuestionStore(),
        empty_gold_standard,
        strictness=strictness,
        answer_counter=counter,
    )
    qs = [
        _stub_question(
            0, "capital of france", correct_answer="Paris", category="general"
        ),
        _stub_question(
            1,
            "seat of the french government",
            correct_answer="Paris",
            category="general",
        ),
        _stub_question(
            2, "where is the louvre", correct_answer="Paris", category="entertainment"
        ),
        _stub_question(
            3,
            "host city of the 2024 olympics",
            correct_answer="Paris",
            category="entertainment",
        ),
    ]
    ctx = _make_ctx(qs)
    result = await stage.run(ctx, sink=_RecordingSink())
    assert [q.id for q in ctx.questions] == ["q_0", "q_2", "q_3"]
    assert result.info["kept"] == 3
    assert result.info["answer_cap"] == 1
    assert result.info["dropped"] == 1
    assert result.info["drop_reasons"]["cosine"] == 0
    # one corpus lookup per (language, category, answer_key) cell, not per question
    assert counter.calls == [
        ("en", "general", "paris"),
        ("en", "entertainment", "paris"),
    ]


@pytest.mark.asyncio
async def test_answer_cap_off_never_touches_the_counter(
    empty_gold_standard: Path,
) -> None:
    counter = _CountingAnswers({("en", "general", "paris"): 99})
    stage = DedupStage(
        _FakeQuestionStore(),
        empty_gold_standard,
        strictness=Strictness(profiles={}, answer_cap=False),
        answer_counter=counter,
    )
    result = await stage.run(
        _make_ctx([_stub_question(0, correct_answer="Paris")]), sink=_RecordingSink()
    )
    assert result.info["kept"] == 1 and counter.calls == []


def test_answer_cap_on_without_counter_fails_loud(empty_gold_standard: Path) -> None:
    with pytest.raises(ValueError, match="answer_counter"):
        DedupStage(
            _FakeQuestionStore(),
            empty_gold_standard,
            strictness=Strictness(profiles={}, answer_cap=True),
        )
