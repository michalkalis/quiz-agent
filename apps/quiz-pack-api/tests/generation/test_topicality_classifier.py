"""Unit tests for TopicalityClassifier (#195 — fresh-question 2× boost).

Why these scenarios: the founder wants topical questions picked ~2× as often
only WHILE they are topical, with the window decided per question (a birthday
last week ≈ a week, an Oscar ≈ a year, Best Picture forever). So (a) the
window must come from the shared ``TIER_TTL`` map counted from the event date,
never from "now" — an old event classified today must NOT come back as fresh;
(b) ``permanent`` must outlive any realistic date; (c) ``none`` (most of the
corpus) is never boosted; and (d) every error path fails safe to "unboosted",
because a broken classifier must never block generation or boost junk.
"""

from __future__ import annotations

import json
from datetime import date, datetime, timedelta, timezone

import pytest
from app.generation.topicality_classifier import (
    PERMANENT_BOOST_UNTIL,
    TIER_TTL,
    Topicality,
    TopicalityClassifier,
    apply_topicality,
    boost_until_for,
)
from quiz_shared.models.question import Question

NOW = datetime(2026, 10, 8, 12, 0, tzinfo=timezone.utc)


def _question(text: str, answer: str = "answer") -> Question:
    return Question(
        id=f"q_{abs(hash(text)) % 10_000}",
        question=text,
        correct_answer=answer,
        topic="General",
        category="entertainment",
        difficulty="medium",
    )


def _classifier_with(response: str) -> TopicalityClassifier:
    """Classifier whose single LLM boundary returns canned text."""
    clf = TopicalityClassifier(api_key="test-key")
    clf.prompts: list[str] = []  # type: ignore[misc]

    async def _fake_complete(prompt: str) -> str:
        clf.prompts.append(prompt)  # type: ignore[attr-defined]
        return response

    clf._complete = _fake_complete  # type: ignore[assignment]
    return clf


# ── tier → boost_until math ─────────────────────────────────────────────────


def test_window_counts_from_event_date_not_from_now() -> None:
    """A last-week birthday stays boosted for TIER_TTL["week"] after the event,
    so it ends sooner than a week from today — the window tracks the news."""
    event = date(2026, 10, 5)
    until = boost_until_for(Topicality("week", event, "r"), NOW)
    assert until == datetime(2026, 10, 5, tzinfo=timezone.utc) + TIER_TTL["week"]
    assert until < NOW + TIER_TTL["week"]


def test_window_already_closed_gives_no_boost() -> None:
    """An event whose window ended before today must not be boosted at all —
    otherwise a late re-classification would resurrect stale news as fresh."""
    stale = Topicality("month", date(2026, 8, 1), "r")  # Aug 1 + 30 d < Oct 8
    assert boost_until_for(stale, NOW) is None


def test_year_tier_uses_its_own_longer_ttl() -> None:
    oscar = Topicality("year", date(2026, 3, 15), "r")
    assert boost_until_for(oscar, NOW) == (
        datetime(2026, 3, 15, tzinfo=timezone.utc) + TIER_TTL["year"]
    )


def test_permanent_is_the_far_future_sentinel_and_none_is_never_boosted() -> None:
    assert boost_until_for(Topicality("permanent", None, "r"), NOW) == PERMANENT_BOOST_UNTIL
    assert PERMANENT_BOOST_UNTIL > NOW + timedelta(days=365 * 1000)
    assert boost_until_for(Topicality("none", None, "r"), NOW) is None


def test_apply_records_verdict_in_provenance_for_review() -> None:
    """The founder audits "why boosted?" per question from provenance."""
    q = _question("Who won Best Actress at the 2026 Oscars?")
    apply_topicality(q, Topicality("year", date(2026, 3, 15), "Oscar result"), NOW)
    assert q.boost_until is not None
    assert q.generation_metadata.extra["topicality"] == {
        "tier": "year",
        "event_date": "2026-03-15",
        "rationale": "Oscar result",
    }


# ── parsing ─────────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_parses_batch_and_gives_model_today() -> None:
    qs = [_question("Who had a birthday last week?"), _question("Capital of France?")]
    clf = _classifier_with(
        json.dumps(
            {
                "classifications": [
                    {"index": 1, "tier": "week", "event_date": "2026-10-03", "rationale": "birthday"},
                    {"index": 2, "tier": "none", "event_date": None, "rationale": "geography"},
                ]
            }
        )
    )
    result = await clf.classify(qs, today=NOW.date())
    assert result[0] == Topicality("week", date(2026, 10, 3), "birthday")
    assert result[1] == Topicality("none", None, "geography")
    assert "Today is 2026-10-08" in clf.prompts[0]  # type: ignore[attr-defined]


@pytest.mark.asyncio
async def test_windowed_tier_without_usable_date_stays_unboosted() -> None:
    """No event date → no window → fail safe, never a guessed boost."""
    clf = _classifier_with(
        json.dumps({"classifications": [{"index": 1, "tier": "month", "event_date": "soon"}]})
    )
    assert await clf.classify([_question("q")]) == [None]


@pytest.mark.asyncio
async def test_unknown_tier_and_out_of_range_index_are_dropped() -> None:
    clf = _classifier_with(
        json.dumps(
            {
                "classifications": [
                    {"index": 1, "tier": "decade", "event_date": "2026-01-01"},
                    {"index": 9, "tier": "permanent"},
                ]
            }
        )
    )
    assert await clf.classify([_question("q")]) == [None]


# ── fail-safe ───────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_garbage_response_fails_safe() -> None:
    assert await _classifier_with("not json").classify([_question("a")]) == [None]


@pytest.mark.asyncio
async def test_llm_exception_never_raises() -> None:
    clf = TopicalityClassifier(api_key="test-key")

    async def _boom(prompt: str) -> str:
        raise RuntimeError("LLM down")

    clf._complete = _boom  # type: ignore[assignment]
    assert await clf.classify([_question("a"), _question("b")]) == [None, None]


@pytest.mark.asyncio
async def test_unavailable_without_key_makes_no_call(monkeypatch) -> None:
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.setenv("LLM_GATEWAY", "direct")
    clf = TopicalityClassifier()
    assert await clf.classify([_question("a")]) == [None]


def test_session_gateway_needs_no_api_key(monkeypatch) -> None:
    """The standalone script must run on the Claude Code subscription."""
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.setenv("LLM_GATEWAY", "session")
    assert TopicalityClassifier()._available() is True
