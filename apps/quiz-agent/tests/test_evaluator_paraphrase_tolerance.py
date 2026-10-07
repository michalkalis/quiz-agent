"""Pilot 2026-07-11 founder concern (raised 3×): the free-text evaluator must
tolerate valid paraphrases of the canonical answer.

Generation stores accepted paraphrases in `alternative_answers`, but the LLM
judge historically never saw them — only the exact-match fast path used them,
so any non-verbatim paraphrase fell to an LLM prompt with no paraphrase rule.
These tests pin the two halves of the fix: alternatives reach the LLM prompt,
and the prompt instructs the judge to accept same-fact paraphrases.
"""

import os

import pytest
from unittest.mock import AsyncMock, MagicMock

os.environ.setdefault("OPENAI_API_KEY", "sk-test")


def _make_question(**overrides):
    from quiz_shared.models.question import Question

    base = dict(
        id="q_para",
        question="How did the man in the field die?",
        type="text",
        correct_answer="His parachute failed to open",
        alternative_answers=["His parachute didn't deploy", "He fell from a plane"],
        topic="Riddles",
        category="general",
        difficulty="medium",
    )
    base.update(overrides)
    return Question(**base)


def _mock_llm_response(content: str):
    message = MagicMock()
    message.content = content
    choice = MagicMock()
    choice.message = message
    response = MagicMock()
    response.choices = [choice]
    return response


class TestParaphraseTolerance:
    @pytest.mark.asyncio
    async def test_alternative_answers_fast_path_still_matches_exactly(self):
        """Verbatim alternative answers keep hitting the deterministic fast
        path — no LLM call, full credit."""
        from app.evaluation.evaluator import AnswerEvaluator

        evaluator = AnswerEvaluator()
        evaluator._llm_evaluate = AsyncMock(
            side_effect=AssertionError("exact alternative must not reach the LLM")
        )

        q = _make_question()
        result, score = await evaluator.evaluate("he fell from a plane", q, q.question)

        assert result == "correct"
        assert score == 1.0

    @pytest.mark.asyncio
    async def test_llm_prompt_carries_alternatives_and_paraphrase_rule(self):
        """A non-verbatim paraphrase goes to the LLM judge, whose prompt must
        list the stored alternatives and state the paraphrase-acceptance rule —
        otherwise leniency silently depends on the judge model's mood."""
        from app.evaluation.evaluator import AnswerEvaluator

        evaluator = AnswerEvaluator()
        evaluator.client = MagicMock()
        evaluator.client.chat.completions.create = AsyncMock(
            return_value=_mock_llm_response("correct")
        )

        q = _make_question()
        result, score = await evaluator.evaluate(
            "the parachute never opened", q, q.question
        )

        assert result == "correct"
        assert score == 1.0
        sent = evaluator.client.chat.completions.create.await_args.kwargs
        prompt = sent["messages"][1]["content"]
        assert "His parachute didn't deploy" in prompt
        assert "He fell from a plane" in prompt
        assert "paraphrases" in prompt.lower()

    @pytest.mark.asyncio
    async def test_llm_prompt_omits_alternatives_block_when_none_stored(self):
        """Questions without alternatives keep a clean prompt — no dangling
        'Also Accepted Answers:' header."""
        from app.evaluation.evaluator import AnswerEvaluator

        evaluator = AnswerEvaluator()
        evaluator.client = MagicMock()
        evaluator.client.chat.completions.create = AsyncMock(
            return_value=_mock_llm_response("incorrect")
        )

        q = _make_question(alternative_answers=[])
        result, score = await evaluator.evaluate("a heart attack", q, q.question)

        assert result == "incorrect"
        assert score == 0.0
        sent = evaluator.client.chat.completions.create.await_args.kwargs
        prompt = sent["messages"][1]["content"]
        assert "Also Accepted Answers:" not in prompt


class TestDifferentEntityRejected:
    """Prod 2026-10-07: "Teflón" was graded correct for "which element besides
    carbon forms the non-stick pan polymer" (answer: fluór). The judge prompt
    accepted "more specific correct answers" and "shorter forms that contain the
    essential element", so a related/containing entity passed. Founder decision:
    naming a DIFFERENT entity than the one asked for is incorrect, not partial."""

    @pytest.mark.asyncio
    async def test_prompt_states_different_entity_rule_without_containment_leniency(
        self,
    ):
        from app.evaluation.evaluator import AnswerEvaluator

        evaluator = AnswerEvaluator()
        evaluator.client = MagicMock()
        evaluator.client.chat.completions.create = AsyncMock(
            return_value=_mock_llm_response("incorrect")
        )

        q = _make_question(
            question="Ktorý prvok okrem uhlíka tvorí polymér na nepriľnavých panviciach?",
            correct_answer="Fluór",
            alternative_answers=["F", "fluór", "ef", "prvok fluór"],
        )
        result, score = await evaluator.evaluate("Teflón. Teflón.", q, q.question)

        assert result == "incorrect"
        assert score == 0.0
        prompt = evaluator.client.chat.completions.create.await_args.kwargs["messages"][
            1
        ]["content"]
        # The different-entity rule, with the Teflon counter-example, is present.
        assert 'DIFFERENT thing than the one asked for is "incorrect"' in prompt
        assert "Teflon" in prompt
        # The leniencies that let a related/containing entity pass are gone.
        assert "More specific correct answers" not in prompt
        assert "contain the essential element" not in prompt
        assert "clearly knows the answer" not in prompt
        # Same-entity tolerance is kept.
        assert "Synonyms, symbols and other-language names" in prompt
        assert "SOUND like the correct answer" in prompt
