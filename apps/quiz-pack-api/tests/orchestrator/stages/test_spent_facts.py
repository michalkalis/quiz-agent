"""Spent-fact exclusion tests (#167, founder directive 2026-09-02).

Intent, one line: **generation must never pay for a question that dedup is
guaranteed to kill.** The #167 pilot fed the full fact list into every top-up
round, so the generator rewrote already-spent facts and `DedupStage` dropped
the results as same-fact reuse — 10 of 14 top-up dedup drops — after their
generation and fact-check had been billed.

Every scenario below is anchored to the dedup leg it mirrors, and each asserts
the DEDUP side too (that the hypothetical question really would be dropped),
so these can't drift into testing a private reimplementation:

- `test_fact_backing_a_kept_question_is_excluded`: the fact-key leg
  (dedup.py:156-163) — same source URL, and the kept answer lives in the fact
  text, so a new question on it lands on the identical `_fact_key`.
- `test_fresh_fact_from_the_same_url_survives`: the pair-key guarantee — one
  page ("2026 in film") carries many facts, so a URL match alone must NOT
  evict a fact whose answer nobody has used.
- `test_same_fact_different_url_is_excluded`: the content-overlap leg
  (dedup.py:164-174) — a re-sourced restatement under a different URL has no
  key collision, so only `_fact_tokens` Jaccard >= 0.35 can catch it.
- `test_unrelated_fact_survives`: the filter must not be a blanket wipe.
- `test_no_kept_questions_passes_pool_through`: the initial round's invariant.
- `test_helpers_are_imported_from_dedup`: anti-fork — a copied threshold or
  tokenizer would let the filter and dedup disagree, which is the one failure
  mode this design exists to rule out (same idiom as
  `tests/scripts/test_filter_postcutoff.py`).
"""

from __future__ import annotations

from typing import Any

from app.orchestrator.stages import spent_facts
from app.orchestrator.stages.spent_facts import SpentFactIndex, filter_spent_facts
from app.orchestrator.stages.dedup import (
    DEFAULT_FACT_JACCARD_THRESHOLD,
    _fact_key,
    _fact_tokens,
    _jaccard,
)
from app.sourcing.models import Fact
from quiz_shared.models.question import Question


def _question(idx: int, text: str, answer: str, **overrides: Any) -> Question:
    base: dict[str, Any] = dict(
        id=f"q_{idx}",
        question=text,
        correct_answer=answer,
        topic="General",
        category="general",
        difficulty="medium",
    )
    base.update(overrides)
    return Question(**base)


# One #167-shaped fact and the question the pilot wrote from it.
_ONE_BATTLE_FACT = Fact(
    text=(
        "Paul Thomas Anderson's One Battle After Another was released in "
        "September 2026 and stars Leonardo DiCaprio."
    ),
    source_url="https://en.wikipedia.org/wiki/2026_in_film",
    topic="Film",
)
_ONE_BATTLE_QUESTION = _question(
    1,
    "Which actor stars in Paul Thomas Anderson's 2026 film "
    "One Battle After Another?",
    "Leonardo DiCaprio",
    source_url="https://en.wikipedia.org/wiki/2026_in_film",
)


def test_fact_backing_a_kept_question_is_excluded() -> None:
    """Fact-key leg: same normalized URL + the kept answer present in the
    fact text → a new question on this fact would collide on `_fact_key`."""
    fresh = Fact(
        text=(
            "Wicked: For Good opened in November 2026 and was directed by "
            "Jon M. Chu."
        ),
        source_url="https://en.wikipedia.org/wiki/2026_in_film",
        topic="Film",
    )

    remaining, spent = filter_spent_facts(
        [_ONE_BATTLE_FACT, fresh], [_ONE_BATTLE_QUESTION]
    )

    assert spent == 1
    assert remaining == [fresh]

    # Dedup side: a second question on the spent fact does collide on the key.
    rewrite = _question(
        2,
        "Who leads the cast of One Battle After Another?",
        "Leonardo DiCaprio",
        source_url="https://EN.wikipedia.org/wiki/2026_in_film/",
    )
    assert _fact_key(rewrite) == _fact_key(_ONE_BATTLE_QUESTION)


def test_fresh_fact_from_the_same_url_survives() -> None:
    """A URL alone is not a fact identity — "2026 in film" carries many
    distinct facts, and evicting them all would starve the top-up round."""
    fresh = Fact(
        text="Wicked: For Good was directed by Jon M. Chu.",
        source_url="https://en.wikipedia.org/wiki/2026_in_film",
        topic="Film",
    )

    assert not SpentFactIndex([_ONE_BATTLE_QUESTION]).is_spent(fresh)

    # Dedup side: distinct answers off one URL are distinct fact keys.
    other = _question(
        2,
        "Who directed Wicked: For Good?",
        "Jon M. Chu",
        source_url="https://en.wikipedia.org/wiki/2026_in_film",
    )
    assert _fact_key(other) != _fact_key(_ONE_BATTLE_QUESTION)


def test_same_fact_different_url_is_excluded() -> None:
    """Content-overlap leg: the same fact re-sourced under a different URL
    has no key collision, so only `_fact_tokens` Jaccard can catch it."""
    restatement = Fact(
        text=(
            "Leonardo DiCaprio stars in One Battle After Another, the 2026 "
            "Paul Thomas Anderson film."
        ),
        source_url="https://www.bbc.com/culture/2026-film-roundup",
        topic="Film",
    )

    index = SpentFactIndex([_ONE_BATTLE_QUESTION])
    assert index.is_spent(restatement)

    # It is genuinely the overlap leg doing the work, not the key leg:
    # different URL means no key match is even possible.
    twin = _question(
        2,
        "Leonardo DiCaprio stars in which 2026 Paul Thomas Anderson film?",
        "One Battle After Another",
        source_url="https://www.bbc.com/culture/2026-film-roundup",
    )
    assert _fact_key(twin) != _fact_key(_ONE_BATTLE_QUESTION)
    assert (
        _jaccard(_fact_tokens(twin), _fact_tokens(_ONE_BATTLE_QUESTION))
        >= DEFAULT_FACT_JACCARD_THRESHOLD
    )


def test_unrelated_fact_survives() -> None:
    """A fact sharing neither URL nor substance must reach the generator."""
    unrelated = Fact(
        text=(
            "The 2026 Eurovision Song Contest was hosted in Vienna after "
            "Austria's win the previous year."
        ),
        source_url="https://en.wikipedia.org/wiki/Eurovision_Song_Contest_2026",
        topic="Music",
    )

    remaining, spent = filter_spent_facts([unrelated], [_ONE_BATTLE_QUESTION])

    assert spent == 0
    assert remaining == [unrelated]


def test_no_kept_questions_passes_pool_through() -> None:
    """Nothing is spent before a question survives — the invariant that keeps
    the initial generation round's pool complete."""
    pool = [_ONE_BATTLE_FACT]

    remaining, spent = filter_spent_facts(pool, [])

    assert spent == 0
    assert remaining == pool


def test_helpers_are_imported_from_dedup() -> None:
    """Anti-fork: a local copy of the tokenizer/thresholds would let the
    filter and DedupStage disagree, which reintroduces the exact waste this
    module removes."""
    for helper in (
        spent_facts._fact_key,
        spent_facts._fact_tokens,
        spent_facts._jaccard,
        spent_facts._normalize_answer,
        spent_facts._normalize_url,
    ):
        assert helper.__module__ == "app.orchestrator.stages.dedup"
    assert (
        spent_facts.DEFAULT_FACT_JACCARD_THRESHOLD
        is DEFAULT_FACT_JACCARD_THRESHOLD
    )
