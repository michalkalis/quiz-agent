"""#160 — answer-blind ShapeClassifier unit tests.

The classifier is the independent second opinion that keeps the
`logical_puzzle` routing marker honest (P4: no model-controlled routing).
Two contracts matter enough to pin:

- **Answer-blind:** the prompt it sends contains the question and options
  only — never the correct answer and never the generator's own label. A
  classifier that saw either would just be the generator grading itself.
- **Fail-closed:** a dead call or unparseable verdict returns ``None``, and
  ``None`` must never read as "logical" — callers route it to factual web
  verification.
"""

from __future__ import annotations

import pytest

from app.verification.shape_classifier import ShapeClassifier


class _FakeMessage:
    def __init__(self, text: str) -> None:
        self.content = text


def _classifier_returning(raw: str | None) -> ShapeClassifier:
    classifier = ShapeClassifier(model="gpt-4o-mini")

    class _Client:
        def __init__(self) -> None:
            self.prompts: list[str] = []

        async def ainvoke(self, prompt: str):
            self.prompts.append(prompt)
            if raw is None:
                raise RuntimeError("provider down")
            return _FakeMessage(raw)

    classifier._client = _Client()
    return classifier


@pytest.mark.asyncio
async def test_prompt_is_answer_blind() -> None:
    classifier = _classifier_returning('{"shape": "logical"}')
    verdict = await classifier.classify(
        "A man pushes his car to a hotel. What happened?",
        {"a": "Monopoly", "b": "Breakdown"},
    )
    assert verdict == "logical"
    prompt = classifier._client.prompts[0]  # type: ignore[attr-defined]
    assert "A man pushes his car" in prompt
    assert "OPTIONS:" in prompt
    # No answer, no label — the classifier must not see either. (Options are
    # fine: blind means blind to WHICH option is correct.)
    assert "CORRECT ANSWER" not in prompt
    assert "lateral_thinking" not in prompt


@pytest.mark.asyncio
async def test_factual_verdict_parses() -> None:
    classifier = _classifier_returning('{"shape": "factual"}')
    assert await classifier.classify("What is the capital of France?") == "factual"


@pytest.mark.asyncio
async def test_dead_call_returns_none_not_logical() -> None:
    classifier = _classifier_returning(None)
    assert await classifier.classify("Anything") is None


@pytest.mark.asyncio
async def test_unparseable_verdict_returns_none() -> None:
    classifier = _classifier_returning("definitely a puzzle, trust me")
    assert await classifier.classify("Anything") is None


@pytest.mark.asyncio
async def test_off_vocabulary_shape_returns_none() -> None:
    classifier = _classifier_returning('{"shape": "riddle"}')
    assert await classifier.classify("Anything") is None
