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
