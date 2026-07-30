"""Prompt-content assertions for the live V3 fact-first prompt (issue #72 P2.1).

Why this test exists
--------------------
`question_generation_v3_fact_first.md` is the **always-used** production
generation prompt: `SourcingStage` was made mandatory on 2026-05-20, so
`use_fact_first` is effectively always true (issue #72, Diagnosis A), which
hard-binds every production run to this prompt. The richer `v2_cot` creative
path is loaded but never reached.

The Feb-2026 commit `471c41b` added the "engagement-path machinery" — the
reasoning patterns 11-13, the Answerability self-critique dimension, the
"Engagement Path over Dead End" principle, and the Structural-Monotony red
flags — to BOTH `v2_cot` and `v3_fact_first` (the latter in v3's
abbreviated-reference form). That machinery is what steers the model away from
boring, first-degree-recall questions ("prvoplánové") toward
estimate / compare / reason questions.

Because the machinery lives only as prompt text, an edit could silently strip
it from the live v3 prompt — exactly the class of regression that degraded
quality on 2026-05-20. Each assertion below fails loudly if a pillar of the
engagement machinery disappears from the live v3 prompt, however the prompt is
otherwise refactored.

This is the P2.1 gate. The "backport" the issue called for was already
satisfied by `471c41b` itself (the machinery is present in v3); these tests
lock it in so it cannot regress out again.
"""

from __future__ import annotations

from pathlib import Path

import app.generation.advanced_generator as adv_gen_module


def _read_v3_prompt() -> str:
    """Read the live v3 prompt from the exact path the generator loads.

    Mirrors `AdvancedQuestionGenerator.__init__` (advanced_generator.py:118):
    `<app/generation>/../../prompts/question_generation_v3_fact_first.md`. By
    resolving from the module file rather than hardcoding a repo path, the test
    tracks the file production code actually reads — if the prompt is moved or
    renamed without updating the loader, this points at the same (missing) path
    and fails.
    """
    prompt_path = (
        Path(adv_gen_module.__file__).resolve().parents[2]
        / "prompts"
        / "question_generation_v3_fact_first.md"
    )
    return prompt_path.read_text(encoding="utf-8")


def test_v3_prompt_offers_the_three_reasoning_patterns() -> None:
    """Patterns 11-13 are the non-recall engagement patterns. Without them the
    live prompt offers only fact-recall framings (patterns 1-6) and output
    regresses to "prvoplánové" recall questions — the exact failure #72 fixes."""
    prompt = _read_v3_prompt()
    assert "The Estimation Challenge" in prompt  # Pattern 11
    assert "The Comparison Bet" in prompt  # Pattern 12
    assert "The Reverse Engineer" in prompt  # Pattern 13


def test_v3_prompt_caps_pure_recall_and_prefers_reasoning() -> None:
    """The batch-shape rule is the only thing capping pure-recall questions; if
    it is dropped the model is free to emit an all-recall (all-boring) batch.
    (2026-07-30 consolidation: the old triple-quota wording collapsed into THE
    CONTRACT's batch-shape rules — same intent, one statement.)"""
    prompt = _read_v3_prompt()
    assert "At least 4 different patterns per batch" in prompt
    assert "no pattern more than 3 times" in prompt
    assert "prefer reasoning patterns (7–13) over recall shapes (1–6)" in prompt


def test_v3_prompt_scores_answerability() -> None:
    """Fair answerability is the in-prompt signal against dead-end recall:
    the player must have a path to the answer besides memory."""
    prompt = _read_v3_prompt()
    assert "Fair answerability" in prompt
    assert "at least one path to the answer besides memory" in prompt


def test_v3_prompt_states_engagement_path_principle() -> None:
    """The engagement-path principle survives as a ranked clause of THE
    CONTRACT's precedence order — fun never outranks a fair reasoning path.
    (Was: 'Engagement Path over Dead End' constitutional principle.)"""
    prompt = _read_v3_prompt()
    assert "(2) fair answerability" in prompt
    assert "discarded no matter how fun" in prompt


def test_v3_prompt_flags_structural_monotony() -> None:
    """The batch-shape opener rules are the guard against the 'every question
    starts with Which' failure mode."""
    prompt = _read_v3_prompt()
    assert 'At most 30% of the batch opens with "Which"' in prompt
    assert "at least 4 different opener structures" in prompt
