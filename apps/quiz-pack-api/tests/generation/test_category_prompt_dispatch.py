"""Category→prompt dispatch: registry loading (issue #76 F-3a).

Why this test exists
--------------------
F-3a introduces the first *prompt-selecting* use of an order's `category`. Until
now `category` was a pure sourcing signal; this adds a general
`{category: PromptBuilder}` registry (`category_prompt_builders`) loaded in
`AdvancedQuestionGenerator.__init__` from `_CATEGORY_PROMPT_FILES`, behind the
same `os.path.exists` guard as the v3/open builders. The dispatch in
`_build_batch_prompt` (a later F-3a task) selects the registered builder over the
generic v3 one — so the whole feature hinges on the registry actually being
populated at construction.

This test pins that load step: if the entertainment prompt file is renamed/moved
or the registry entry is dropped, generation would silently fall back to the
generic v3 prompt (losing the entertainment tone + driving-safety rules) and the
only symptom would be blander questions in the corpus. Catching it here turns a
silent regression into a loud unit-test failure.

It is also the general-map guarantee in test form: the assertion is on a
*registry keyed by category*, not on an `entertainment`-named attribute — which
is exactly what lets kids/themed register later by adding one line, no new
branch (decisions 3, 2d).
"""

from __future__ import annotations

import pytest

from app.generation.advanced_generator import AdvancedQuestionGenerator
from app.generation.prompt_builder import PromptBuilder


@pytest.fixture(autouse=True)
def _stub_openai_key(monkeypatch: pytest.MonkeyPatch) -> None:
    """Avoid ChatOpenAI's env-var assertion at construction time."""
    monkeypatch.setenv("OPENAI_API_KEY", "test-key-not-used")


def test_entertainment_prompt_registered_at_construction() -> None:
    """The entertainment fact-first prompt loads into the general category
    registry as a usable PromptBuilder, so `_build_batch_prompt` can dispatch to
    it for a `category="entertainment"` order instead of the generic v3 prompt.

    Asserting on the keyed registry (not an `entertainment` attribute) is the
    point: future categories register the same way with no new branch.
    """
    gen = AdvancedQuestionGenerator(
        generation_model="gpt-4o",
        critique_model="gpt-4o-mini",
        prompt_version="v3_fact_first",
    )
    assert "entertainment" in gen.category_prompt_builders
    assert isinstance(gen.category_prompt_builders["entertainment"], PromptBuilder)
