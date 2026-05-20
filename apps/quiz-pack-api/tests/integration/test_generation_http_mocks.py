"""Generation-layer HTTP mock smoke test (issue #36 task 2.11c).

Constructs a real ``AdvancedQuestionGenerator`` and asserts ``generate_questions``
returns the expected number of ``Question`` objects when OpenAI ChatCompletion
HTTP is intercepted by the ``generation_http_mocks`` fixture.

The canned response shape in ``conftest._generation_payload`` is the contract
between the V3 fact-first prompt template and ``_parse_response`` — if a future
refactor changes the parser's expected JSON shape, this test breaks loudly.
"""

from __future__ import annotations

import pytest

from app.generation.advanced_generator import AdvancedQuestionGenerator
from app.sourcing.models import Fact


@pytest.fixture(autouse=True)
def _openai_api_key(monkeypatch: pytest.MonkeyPatch) -> None:
    """``ChatOpenAI`` refuses to initialize without an API key."""
    monkeypatch.setenv("OPENAI_API_KEY", "test-key-for-mocks")


def _stub_facts(n: int) -> list[Fact]:
    return [
        Fact(
            text=f"Stub fact #{i}: surprising biology detail.",
            source_url=f"https://example.com/fact/{i}",
            source_name="example",
            topic="Biology",
            surprise_rating=7.5,
        )
        for i in range(n)
    ]


async def test_advanced_generator_returns_questions_under_mocks(
    generation_http_mocks,
) -> None:
    """Generator parses the canned response into Question objects.

    ``enable_best_of_n=False`` avoids the per-question critique pass — the
    critique route is still registered (by ``generation_http_mocks``) so the
    e2e test in 2.11e can reuse the same fixture group.
    """
    generator = AdvancedQuestionGenerator()
    questions = await generator.generate_questions(
        count=3,
        difficulty="medium",
        topics=["science"],
        categories=["science"],
        source_facts=_stub_facts(5),
        enable_best_of_n=False,
    )

    assert len(questions) == 3, (
        f"expected 3 questions from canned response, got {len(questions)}"
    )
    for q in questions:
        assert q.generation_metadata is not None
        assert q.generation_metadata.pipeline == "fact_first", (
            f"source_facts should trigger V3 fact-first pipeline, got "
            f"{q.generation_metadata.pipeline!r}"
        )
        assert q.correct_answer, "parsed question must carry a correct_answer"
        assert q.source_url, "V3 prompt response carries source_url through"
