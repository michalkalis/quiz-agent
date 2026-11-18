"""Unit tests for LocalScopeClassifier (#206 — "skip local questions").

Why these scenarios: a player who switches local questions off must get none,
and a player who keeps them on must lose nothing. So (a) the verdict is the
COUNTRY, kept exactly as the model gave it (Bratislava public transport → sk,
prší → cz, a US state capital → us) and null means universal (Kafka); (b) a
universal verdict is still recorded, because "classified universal" and "never
classified" must stay distinguishable for the resumable backfill; and (c)
every error path fails safe to "no verdict" — unlabelled rows are served as
universal and retried later, never dropped or wrongly hidden.
"""

from __future__ import annotations

import json

import pytest
from app.generation.local_scope_classifier import (
    LocalScope,
    LocalScopeClassifier,
    apply_local_scope,
    has_local_scope_verdict,
)
from quiz_shared.models.question import GenerationProvenance, Question


def _question(text: str, answer: str = "answer", language: str = "en") -> Question:
    return Question(
        id=f"q_{abs(hash(text)) % 10_000}",
        question=text,
        correct_answer=answer,
        topic="General",
        category="general",
        difficulty="medium",
        language=language,
    )


BOUNDARY = [
    _question("Ktorá linka MHD v Bratislave chodí na Kamzík?", "44", "sk"),
    _question("Kolik karet dostane hráč na začátku hry prší?", "4", "cs"),
    _question("Who wrote The Metamorphosis?", "Franz Kafka"),
    _question("What is the capital of the US state of Vermont?", "Montpelier"),
]


def _classifier_with(response: str | None) -> LocalScopeClassifier:
    clf = LocalScopeClassifier(model="claude-sonnet-5-5")
    clf.prompts: list[str] = []  # type: ignore[misc]

    async def _fake_complete(prompt: str) -> str | None:
        clf.prompts.append(prompt)  # type: ignore[attr-defined]
        return response

    clf._complete = _fake_complete  # type: ignore[assignment]
    return clf


def _labels(*scopes: str | None) -> str:
    return json.dumps(
        {
            "labels": [
                {"index": i, "local_scope": s, "reason": f"r{i}"}
                for i, s in enumerate(scopes, start=1)
            ]
        }
    )


@pytest.fixture(autouse=True)
def _llm_reachable(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        "app.generation.local_scope_classifier.llm_factory.chat_available",
        lambda model: True,
    )


@pytest.mark.asyncio
async def test_boundary_cases_keep_the_country_and_null_means_universal() -> None:
    clf = _classifier_with(_labels("sk", "cz", None, "us"))
    verdicts = await clf.classify(BOUNDARY)
    assert [v.scope for v in verdicts] == ["sk", "cz", None, "us"]
    # The model sees each question's language, so it can tell a Slovak-worded
    # universal question from a Slovak-only fact.
    assert "[sk] Q: Ktorá linka MHD" in clf.prompts[0]


@pytest.mark.asyncio
async def test_country_codes_are_normalised_and_garbage_is_not_a_label() -> None:
    """'SK' is fine; 'Slovakia' or 'cs' (language) is not an ISO country —
    better unlabelled (retried) than a scope the retriever cannot reason about."""
    clf = _classifier_with(_labels("SK", "Slovakia", "", 42))
    verdicts = await clf.classify(BOUNDARY)
    assert verdicts[0].scope == "sk"
    assert verdicts[1] is None
    assert verdicts[2].scope is None  # empty string = universal
    assert verdicts[3] is None


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "response",
    [None, "not json at all", '{"other": []}', '{"labels": [{"index": 9, "local_scope": "sk"}]}'],
)
async def test_failures_leave_questions_unlabelled_never_raise(response) -> None:
    verdicts = await _classifier_with(response).classify(BOUNDARY)
    assert verdicts == [None] * len(BOUNDARY)


@pytest.mark.asyncio
async def test_unreachable_model_skips_the_call(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        "app.generation.local_scope_classifier.llm_factory.chat_available",
        lambda model: False,
    )
    clf = _classifier_with(_labels("sk"))
    assert await clf.classify(BOUNDARY[:1]) == [None]
    assert clf.prompts == []


def test_universal_verdict_is_recorded_so_backfill_skips_it() -> None:
    q = _question("Who wrote The Metamorphosis?", "Franz Kafka")
    q.generation_metadata = GenerationProvenance(extra={"topicality": {"tier": "none"}})
    assert not has_local_scope_verdict(q)

    apply_local_scope(q, LocalScope(scope=None, reason="world literature"))

    assert q.local_scope is None
    assert has_local_scope_verdict(q)
    assert q.generation_metadata.extra["local_scope"]["reason"] == "world literature"
    assert q.generation_metadata.extra["topicality"] == {"tier": "none"}  # untouched


@pytest.mark.asyncio
async def test_label_batches_and_applies_only_real_verdicts() -> None:
    questions = [_question(f"q{i}") for i in range(30)]
    clf = _classifier_with(_labels(*(["cz"] * 25)))
    labelled = await clf.label(questions, batch_size=25)
    # Second batch (5 rows) gets a 25-item reply: indexes 6..25 out of range,
    # 1..5 match — every row ends up labelled exactly once.
    assert labelled == 30
    assert len(clf.prompts) == 2
    assert all(q.local_scope == "cz" for q in questions)
