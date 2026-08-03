"""The prompt example corpus must ship with the image, or generation must fail.

Why this file exists (adversarial audit 2026-07-30): the deployed image carried
no `data/` at all — the Dockerfile copied only `apps/quiz-pack-api` +
`packages/shared`. `load_gold_standard` therefore fell back to five hardcoded
exemplars and `load_anti_patterns` returned "", so every paid pack was generated
with none of the 53 curated gold examples, no anti-pattern block, and a no-op
gold-standard dedup check. Nothing logged it, and the fallback exemplars taught
shapes the pipeline elsewhere bans (a language-dependent anagram, a non-metric
figure). Local runs looked fine because the repo `data/` exists.

So the contract has two halves and both are pinned here:
- the loaders resolve the corpus by walking up from the module (works in the
  repo checkout and in the Docker `/app` layout) and RAISE when it is absent,
  instead of silently degrading;
- the packaging that puts it in the image (Dockerfile COPY + the `.dockerignore`
  re-include) stays in place — a static check, since a real `docker build` is
  not available in CI.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.generation import examples
from app.generation.examples import (
    _diverse_sample,
    example_corpus_path,
    load_anti_patterns,
    load_gold_standard,
)

REPO_ROOT = Path(__file__).resolve().parents[4]
DOCKERFILE = REPO_ROOT / "apps" / "quiz-pack-api" / "Dockerfile"
DOCKERIGNORE = REPO_ROOT / ".dockerignore"


def test_gold_standard_resolves_and_renders_the_real_library() -> None:
    """The rendered block must come from the curated library, not a stand-in.

    Every rendered question is checked against the on-disk corpus: that is what
    distinguishes "the 53-entry library reached the prompt" from "five hardcoded
    examples did", which is exactly the failure that ran in prod unnoticed.
    """
    corpus = json.loads(example_corpus_path("gold_standard.json").read_text("utf-8"))
    known_questions = {e["question"] for e in corpus}

    rendered = load_gold_standard(n=5)

    quoted = [
        line.split('Q: "', 1)[1].rsplit('"', 1)[0]
        for line in rendered.splitlines()
        if line.startswith('Q: "')
    ]
    assert quoted, "no questions rendered into the prompt block"
    assert set(quoted) <= known_questions


def test_anti_patterns_resolve_and_render() -> None:
    """An empty anti-pattern section removes the whole "Avoid these!" block from
    the prompt, so a silent "" is a real quality regression, not cosmetic."""
    rendered = load_anti_patterns(n=5)

    assert "**BAD:**" in rendered
    assert "**Why it's bad:**" in rendered


def test_missing_gold_standard_raises_instead_of_degrading(monkeypatch) -> None:
    """With the corpus absent, generation must stop loudly.

    The old code returned hardcoded exemplars here, which is why the defect
    survived two deploys with nothing in the logs.
    """
    monkeypatch.setattr(examples, "find_in_ancestors", lambda *_a, **_k: None)

    with pytest.raises(FileNotFoundError, match="gold_standard.json"):
        load_gold_standard(n=5)


def test_missing_anti_patterns_raises_instead_of_empty_section(monkeypatch) -> None:
    """Same policy for anti-patterns: previously a missing file returned "",
    which the prompt builder treats as "no anti-pattern section needed"."""
    monkeypatch.setattr(examples, "find_in_ancestors", lambda *_a, **_k: None)

    with pytest.raises(FileNotFoundError, match="anti_patterns.json"):
        load_anti_patterns(n=5)


def test_no_hardcoded_gold_standard_fallback_remains() -> None:
    """Re-introducing a hardcoded exemplar block would restore the silent
    degradation this fix removed, so the absence is part of the contract."""
    assert not hasattr(examples, "EXCELLENT_EXAMPLES")


def test_image_packaging_ships_the_corpus() -> None:
    """Pins the two lines that put the corpus in the image.

    Dropping either one puts prod straight back into the audited state; the
    Dockerfile COPY at least fails the build, but the `.dockerignore` negation
    is the part that makes it visible at all.
    """
    assert "COPY data/examples /app/data/examples" in DOCKERFILE.read_text("utf-8")
    assert "!data/examples/" in DOCKERIGNORE.read_text("utf-8").splitlines()


# --- Diversity-aware selection (founder-approved, 2026-08) ---------------------


def _pattern_pool(patterns: list[str], topic: str = "science") -> list[dict]:
    return [
        {
            "pattern": p,
            "topic": topic,
            "question": f"Q about {p} #{i}",
            "answer": "A",
            "why_excellent": "generic craft reasoning",
        }
        for i, p in enumerate(patterns)
    ]


def test_diverse_sample_guarantees_pairwise_distinct_patterns_when_pool_allows() -> None:
    """A plain `random.sample` could (and did) hand a batch several exemplars
    of the SAME pattern, over-anchoring generation on one shape. With >= k
    distinct pattern values in the pool, every pick must differ."""
    pool = _pattern_pool(["A", "B", "C", "D", "E", "F"])
    for _ in range(30):
        picked = _diverse_sample(pool, 4)
        patterns = [ex["pattern"] for ex in picked]
        assert len(patterns) == len(set(patterns)) == 4


def test_diverse_sample_still_random_within_the_constraint() -> None:
    """The diversity constraint must not collapse to one deterministic pick —
    still random among the pattern-diverse combinations."""
    pool = _pattern_pool(["A", "B", "C", "D", "E", "F"])
    seen = {tuple(sorted(ex["pattern"] for ex in _diverse_sample(pool, 3))) for _ in range(40)}
    assert len(seen) > 1


def test_diverse_sample_falls_back_to_distinct_topic_when_patterns_exhausted() -> None:
    """With too few distinct patterns to satisfy pairwise-distinctness, the
    secondary preference (distinct `topic`) still kicks in where the pool
    allows it."""
    pool = [
        {"pattern": "P1", "topic": "science", "question": "q1", "answer": "a", "why_excellent": "x"},
        {"pattern": "P1", "topic": "science", "question": "q2", "answer": "a", "why_excellent": "x"},
        {"pattern": "P1", "topic": "history", "question": "q3", "answer": "a", "why_excellent": "x"},
        {"pattern": "P1", "topic": "art", "question": "q4", "answer": "a", "why_excellent": "x"},
    ]
    for _ in range(20):
        picked = _diverse_sample(pool, 3)
        topics = [ex["topic"] for ex in picked]
        assert len(set(topics)) == 3  # all 3 distinct topics in the pool, all surfaced


# --- Answer-omitted examples always annotate, unless that would leak -----------


def _pin_shuffle_order(monkeypatch: pytest.MonkeyPatch) -> None:
    """Make `_diverse_sample`'s internal shuffle a no-op so selection order
    matches input order — the annotation tests below need to know exactly
    which crafted example lands in the answer-omitted tail slot."""
    monkeypatch.setattr(examples.random, "shuffle", lambda seq: None)


def test_load_gold_standard_annotates_answer_omitted_example_when_safe(
    tmp_path, monkeypatch
) -> None:
    """Every selected example — including the answer-omitted tail — must
    render `**WHY EXCELLENT:**` when doing so does not leak the hidden
    answer. Previously the tail rendered nothing but the generic note."""
    data = [
        {
            "question": "Full example question?",
            "answer": "Nutmeg",
            "why_excellent": "shown in full, always safe to render",
            "pattern": "Surprising Connection",
            "human_rating": 9,
        },
        {
            "question": "Answer-omitted example question?",
            "answer": "Carbon",
            "why_excellent": "Links three everyday objects through shared chemistry.",
            "pattern": "Hidden Property",
            "human_rating": 9,
        },
    ]
    (tmp_path / "gold_standard.json").write_text(json.dumps(data), encoding="utf-8")
    monkeypatch.setattr(
        examples, "example_corpus_path", lambda filename: tmp_path / filename
    )
    _pin_shuffle_order(monkeypatch)

    rendered = load_gold_standard(n=2)

    # n=2 -> full_count = max(2-2, 1) = 1: example 1 is full, example 2 is the
    # answer-omitted tail. Its answer ("Carbon") never appears verbatim in its
    # `why_excellent`, so the safe path renders the annotation.
    tail = rendered.split("**Example 2:")[1]
    assert "**WHY EXCELLENT:** Links three everyday objects" in tail
    assert "A: Carbon" not in tail  # answer itself still omitted
    assert "Answer omitted" not in tail


def test_load_gold_standard_keeps_pattern_only_note_when_why_excellent_leaks_answer(
    tmp_path, monkeypatch
) -> None:
    """When the answer-omitted tail's own `why_excellent` text contains its
    hidden answer (case-insensitive), rendering it would leak the answer
    through the annotation — the safeguard keeps the old pattern-only note
    instead."""
    data = [
        {
            "question": "Full example question?",
            "answer": "Nutmeg",
            "why_excellent": "shown in full, always safe to render",
            "pattern": "Surprising Connection",
            "human_rating": 9,
        },
        {
            "question": "Answer-omitted example question?",
            "answer": "Carbon",
            "why_excellent": "The element CARBON links pencils, rackets, and diamonds.",
            "pattern": "Hidden Property",
            "human_rating": 9,
        },
    ]
    (tmp_path / "gold_standard.json").write_text(json.dumps(data), encoding="utf-8")
    monkeypatch.setattr(
        examples, "example_corpus_path", lambda filename: tmp_path / filename
    )
    _pin_shuffle_order(monkeypatch)

    rendered = load_gold_standard(n=2)

    tail = rendered.split("**Example 2:")[1]
    assert "Answer omitted" in tail
    assert "**WHY EXCELLENT:**" not in tail
    assert "carbon" not in tail.lower()  # the leak the safeguard exists to prevent


# --- Contrastive anti-pattern rendering (founder-approved, 2026-08) -------------


def test_load_anti_patterns_renders_contrastive_fixed_block_when_present(
    tmp_path, monkeypatch
) -> None:
    """An entry carrying the `fixed_question`/`fixed_answer`/`why_fixed` triad
    must render the BAD -> FIXED contrastive shape, not just the failure."""
    data = [
        {
            "question": "What is the capital of Australia?",
            "answer": "Canberra",
            "why_bad": "Boring lookup format.",
            "fixed_question": "Which country's capital most tourists guess wrong?",
            "fixed_answer": "Australia (Canberra, not Sydney)",
            "why_fixed": "Reframes the same fact as a surprising misconception.",
        }
    ]
    (tmp_path / "anti_patterns.json").write_text(json.dumps(data), encoding="utf-8")
    monkeypatch.setattr(
        examples, "example_corpus_path", lambda filename: tmp_path / filename
    )

    rendered = load_anti_patterns(n=1)

    assert '**BAD:** "What is the capital of Australia?" -> Canberra' in rendered
    assert "**Why it's bad:** Boring lookup format." in rendered
    assert (
        '**FIXED (same fact, done right):** '
        '"Which country\'s capital most tourists guess wrong?" -> '
        'Australia (Canberra, not Sydney)'
    ) in rendered
    assert (
        "**Why the fix works:** Reframes the same fact as a surprising "
        "misconception."
    ) in rendered


def test_load_anti_patterns_keeps_legacy_format_without_fixed_fields() -> None:
    """An entry without the fixed-* triad keeps today's BAD-only format —
    the real anti_patterns.json has no such fields yet."""
    rendered = load_anti_patterns(n=5)

    assert "FIXED (same fact, done right)" not in rendered
    assert "Why the fix works" not in rendered
