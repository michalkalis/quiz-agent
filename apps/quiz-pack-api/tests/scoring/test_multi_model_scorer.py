"""Unit tests for MultiModelScorer advisory dimensions (issue #42 task 42.6).

Why these scenarios:

- The deterministic ``answer_brevity`` and ``distractor_quality``
  dimensions are how the post-generation validator (42.7) and the
  Track A cleanup scripts surface "voice-unfriendly canonical
  answer" and "leaky MCQ distractor" without an LLM call.
- The score must be reproducible across re-runs (the plan acceptance
  calls out "seeded LLM mock"; deterministic helpers exceed that
  bar — same input always returns the same int).
- ``distractor_quality`` must return ``None`` for non-MCQ questions
  so downstream code can distinguish "not applicable" from "scored
  low". A 0/1 sentinel would silently mark every plain-text
  question as a bad distractor set.
- A synthetic ``deterministic`` entry must still be emitted when no
  LLM model is configured, otherwise the new advisory dims would
  vanish in test/CI environments where no API key is set — the
  whole point of the dims is "always logged".
"""

from __future__ import annotations

from typing import Any
from unittest.mock import AsyncMock

import pytest

from app.scoring.multi_model_scorer import (
    MultiModelScorer,
    compute_answer_brevity,
    compute_distractor_quality,
)


# ---------------------------------------------------------------------------
# answer_brevity
# ---------------------------------------------------------------------------


def test_answer_brevity_short_clean_answer_scores_max() -> None:
    """≤5 words, no explanation tail → top score (10)."""
    assert compute_answer_brevity("Paris") == 10
    assert compute_answer_brevity("The Battle of Waterloo") == 10


def test_answer_brevity_mid_length_clean_answer_scores_mid() -> None:
    """6–10 words, no tail → mid score (7) — within cap but not ideal."""
    answer = "Marie Curie won the Nobel Prize in Physics"
    assert compute_answer_brevity(answer) == 7


def test_answer_brevity_em_dash_explanation_penalised() -> None:
    """Em-dash explanation tail trips the penalty even if short overall."""
    answer = "Jupiter — because it has the most mass"
    assert compute_answer_brevity(answer) <= 3


def test_answer_brevity_because_tail_penalised() -> None:
    """``because`` tail mid-sentence is a classic verbose-answer shape."""
    answer = "Carbon dioxide because plants absorb it for photosynthesis"
    assert compute_answer_brevity(answer) <= 3


def test_answer_brevity_long_and_tail_scores_min() -> None:
    """Both word-cap and tail violations → minimum (1)."""
    answer = (
        "Basketball — its rules were written by James Naismith in December "
        "1891, while the modern marathon distance was only standardised at "
        "the 1908 London Olympics"
    )
    assert compute_answer_brevity(answer) == 1


def test_answer_brevity_handles_list_correct_answer() -> None:
    """Question.correct_answer can be ``list[str]`` for multi-select; the
    helper must not crash and must judge the joined form."""
    assert compute_answer_brevity(["Paris", "London"]) == 10


def test_answer_brevity_empty_or_none_scores_min() -> None:
    assert compute_answer_brevity("") == 1
    assert compute_answer_brevity(None) == 1


def test_answer_brevity_is_deterministic() -> None:
    """Same input → same output across calls. Locks the reproducibility
    contract the plan acceptance asks for."""
    answer = "M. C. Escher"
    assert compute_answer_brevity(answer) == compute_answer_brevity(answer)


# ---------------------------------------------------------------------------
# distractor_quality
# ---------------------------------------------------------------------------


def test_distractor_quality_none_for_non_mcq() -> None:
    """Plain-text questions have no ``possible_answers``; the dim must
    return None so consumers don't conflate "no MCQ" with "bad MCQ"."""
    assert compute_distractor_quality("Paris", None) is None
    assert compute_distractor_quality("Paris", {}) is None


def test_distractor_quality_plausible_set_scores_high() -> None:
    """All distractors distinct, similar length, none leaking the
    correct value → top score."""
    options = {"a": "Mercury", "b": "Venus", "c": "Mars", "d": "Jupiter"}
    assert compute_distractor_quality("d", options) == 10


def test_distractor_quality_substring_leak_penalised() -> None:
    """A distractor that contains the correct value as a substring
    telegraphs the answer (or vice-versa)."""
    options = {"a": "Paris", "b": "Paris, France", "c": "London", "d": "Rome"}
    assert compute_distractor_quality("a", options) <= 7


def test_distractor_quality_duplicate_distractor_penalised() -> None:
    """Two identical distractors collapse the question to a 3-way
    pick — unanswerable."""
    options = {"a": "Paris", "b": "London", "c": "London", "d": "Rome"}
    assert compute_distractor_quality("a", options) <= 6


def test_distractor_quality_accepts_value_as_correct_answer() -> None:
    """The generator sometimes emits ``correct_answer`` as the literal
    value, not the key letter — both shapes must be supported."""
    options = {"a": "Mercury", "b": "Venus", "c": "Mars", "d": "Jupiter"}
    assert compute_distractor_quality("Jupiter", options) == 10


def test_distractor_quality_length_skew_penalised() -> None:
    """Distractors wildly shorter or longer than the correct value
    give the answer away by shape."""
    options = {
        "a": "Yes",
        "b": "Albert Einstein, born in Ulm in 1879, theory of relativity",
        "c": "No",
        "d": "Maybe",
    }
    # b is the leak: massively longer than the others
    assert compute_distractor_quality("b", options) <= 7


def test_distractor_quality_unknown_correct_answer_returns_none() -> None:
    """If the supplied ``correct_answer`` doesn't match any key or
    value in the options dict we can't judge the distractors — return
    None rather than score a bogus value."""
    options = {"a": "Paris", "b": "London"}
    assert compute_distractor_quality("Berlin", options) is None


# ---------------------------------------------------------------------------
# MultiModelScorer integration
# ---------------------------------------------------------------------------


class _StubResponse:
    def __init__(self, content: str) -> None:
        self.content = content


@pytest.mark.asyncio
async def test_score_question_merges_deterministic_dims_into_llm_result(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """One dimension per call (2026-07-30 redesign): each judge call returns a
    single {"score", "reasoning"} verdict; the scorer assembles the dims dict,
    computes overall deterministically (never trusting an LLM overall_score),
    and merges the deterministic dims alongside — not on a separate entry."""
    scorer = MultiModelScorer(models=[
        {"provider": "openai", "model": "gpt-5.6-sol", "name": "gpt-5.6-sol"}
    ])
    fake_client = AsyncMock()
    fake_client.ainvoke.return_value = _StubResponse(
        '{"score": 7, "reasoning": "stubbed"}'
    )
    monkeypatch.setattr(scorer, "_get_client", lambda _cfg: fake_client)

    out = await scorer.score_question(
        question="Which planet has the most mass?",
        answer="Jupiter",
        possible_answers={"a": "Mars", "b": "Jupiter", "c": "Saturn", "d": "Earth"},
    )

    assert len(out) == 1
    scores = out[0]["scores"]
    from app.scoring.multi_model_scorer import SCORING_DIMENSIONS

    for dim_key in SCORING_DIMENSIONS:  # every dimension got its own call
        assert scores[dim_key] == 7
    assert out[0]["overall_score"] == 7.0  # computed in code, not by the LLM
    assert scores["answer_brevity"] == 10  # deterministic dim merged
    assert scores["distractor_quality"] == 10  # deterministic dim merged
    # A3: every judge prompt must carry the options and the answer TEXT.
    prompt_sent = fake_client.ainvoke.call_args_list[0].args[0][0].content
    assert "OPTIONS:" in prompt_sent
    assert "Jupiter" in prompt_sent


@pytest.mark.asyncio
async def test_score_question_drops_judge_after_failed_retry(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A6: an unparseable judge is retried once, then dropped loudly — never
    defaulted to a neutral score. With no judge left, the synthetic
    deterministic entry keeps the advisory dims logged."""
    scorer = MultiModelScorer(models=[
        {"provider": "openai", "model": "gpt-5.6-sol", "name": "gpt-5.6-sol"}
    ])
    fake_client = AsyncMock()
    fake_client.ainvoke.return_value = _StubResponse("no json here at all")
    monkeypatch.setattr(scorer, "_get_client", lambda _cfg: fake_client)

    out = await scorer.score_question(
        question="Which planet has the most mass?",
        answer="Jupiter",
    )

    assert len(out) == 1
    assert out[0]["model_name"] == "deterministic"
    # one dimension set of calls, each retried once
    from app.scoring.multi_model_scorer import SCORING_DIMENSIONS

    assert fake_client.ainvoke.await_count == 2 * len(SCORING_DIMENSIONS)


@pytest.mark.asyncio
async def test_score_question_emits_deterministic_only_entry_when_no_models() -> None:
    """Test/CI without API keys configures zero models — but the
    advisory dims must still appear, so a synthetic entry is emitted."""
    # Constructor falls back to defaults when ``models`` is falsy, so
    # set the empty list directly to simulate "no LLM available".
    scorer = MultiModelScorer(models=[{"provider": "openai", "model": "x", "name": "x"}])
    scorer.models = []

    out = await scorer.score_question(
        question="Which planet has the most mass?",
        answer="Jupiter",
    )

    assert len(out) == 1
    assert out[0]["model_name"] == "deterministic"
    assert out[0]["scores"]["answer_brevity"] == 10
    assert "distractor_quality" not in out[0]["scores"]  # no MCQ context


@pytest.mark.asyncio
async def test_score_batch_threads_possible_answers_through(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The orchestrator stage passes ``possible_answers`` in the batch
    payload (issue #42 task 42.6 — stage update). ``score_batch``
    must forward it so ``distractor_quality`` is computed."""
    scorer = MultiModelScorer(models=[])
    captured: list[Any] = []

    async def _spy_score_question(**kwargs: Any) -> list[dict]:
        captured.append(kwargs)
        return [{"model_name": "deterministic", "scores": {}, "overall_score": 1.0}]

    monkeypatch.setattr(scorer, "score_question", _spy_score_question)

    await scorer.score_batch([
        {
            "id": "q_0",
            "question": "Which planet?",
            "correct_answer": "Jupiter",
            "possible_answers": {"a": "Mars", "b": "Jupiter"},
        }
    ])

    assert captured[0]["possible_answers"] == {"a": "Mars", "b": "Jupiter"}


# ---------------------------------------------------------------------------
# Gate v2 clustered mode + Bedrock judges (#135 T6 fallback, 2026-08-04)
# ---------------------------------------------------------------------------


_PANEL_JSON = (
    '{"dimensions": {'
    '"conversation_spark": {"reasoning": "r", "score": 6}, '
    '"surprise_delight": {"reasoning": "r", "score": 7}, '
    '"tellability": {"reasoning": "r", "score": 8}, '
    '"clever_framing": {"reasoning": "r", "score": 4}, '
    '"answerability": {"reasoning": "r", "score": 5}}}'
)


@pytest.mark.asyncio
async def test_gate_v2_clustered_merges_two_calls_per_judge(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Clustered mode exists to undo the cross-dimension contamination of the
    single panel call WITHOUT paying v1's per-dimension cost: each judge must
    get exactly one call per cluster, each cluster prompt must carry only its
    own dimensions, and the judge's overall must still be the mean of all 5."""
    from app.scoring.multi_model_scorer import GATE_V2_CLUSTERS

    scorer = MultiModelScorer(
        models=[{"provider": "openai", "model": "m", "name": "m"}],
        gate_v2=True,
        gate_v2_clustered=True,
    )
    fake_client = AsyncMock()
    fake_client.ainvoke.return_value = _StubResponse(_PANEL_JSON)
    monkeypatch.setattr(scorer, "_get_client", lambda _cfg: fake_client)

    out = await scorer.score_question(question="Q?", answer="A")

    assert fake_client.ainvoke.await_count == len(GATE_V2_CLUSTERS)
    prompts = [c.args[0][0].content for c in fake_client.ainvoke.call_args_list]
    fun_prompt = next(p for p in prompts if "conversation_spark" in p)
    craft_prompt = next(p for p in prompts if "clever_framing" in p)
    assert "clever_framing" not in fun_prompt  # cluster isolation
    assert "conversation_spark" not in craft_prompt
    assert "THE THREE DIMENSIONS" in fun_prompt
    assert "THE TWO DIMENSIONS" in craft_prompt

    scores = out[0]["scores"]
    for dim in ("conversation_spark", "tellability", "answerability"):
        assert dim in scores  # both clusters merged into one judge entry
    assert out[0]["overall_score"] == 6.0  # mean of 6,7,8,4,5 — code-computed


@pytest.mark.asyncio
async def test_gate_v2_clustered_partial_failure_keeps_other_cluster(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A6 fail-loud carry-over: when one cluster call fails after its retry,
    the judge keeps the other cluster's dimensions (logged as missing) rather
    than dropping the whole judge or defaulting scores."""
    scorer = MultiModelScorer(
        models=[{"provider": "openai", "model": "m", "name": "m"}],
        gate_v2=True,
        gate_v2_clustered=True,
    )
    fake_client = AsyncMock()

    async def _ainvoke(messages: Any) -> _StubResponse:
        if "clever_framing" in messages[0].content:
            return _StubResponse("no json")
        return _StubResponse(_PANEL_JSON)

    fake_client.ainvoke.side_effect = _ainvoke
    monkeypatch.setattr(scorer, "_get_client", lambda _cfg: fake_client)

    out = await scorer.score_question(question="Q?", answer="A")

    scores = out[0]["scores"]
    assert "conversation_spark" in scores
    assert "clever_framing" not in scores
    assert out[0]["overall_score"] == 7.0  # mean of the 3 fun dims only


def test_parse_gate_v2_response_respects_dim_subset() -> None:
    """Cluster parsing must ignore dimensions outside its cluster — otherwise
    a model echoing all 5 dims would smuggle unvalidated scores past the
    cluster split and both calls would double-count."""
    from app.scoring.multi_model_scorer import _parse_gate_v2_response

    parsed = _parse_gate_v2_response(
        _PANEL_JSON, dim_keys=("clever_framing", "answerability")
    )
    assert set(parsed) == {"clever_framing", "answerability"}


def test_response_text_extracts_bedrock_content_blocks() -> None:
    """Bedrock Converse reasoning judges (R1/gpt-oss) return typed blocks;
    chain-of-thought must not reach the JSON parser — only text blocks do."""
    from app.scoring.multi_model_scorer import _response_text

    resp = _StubResponse("plain")
    assert _response_text(resp) == "plain"

    resp = _StubResponse("x")
    resp.content = [
        {"type": "reasoning_content", "reasoning_content": {"text": "cot"}},
        {"type": "text", "text": '{"score": 5}'},
    ]
    assert _response_text(resp) == '{"score": 5}'


def test_judge_models_override_gates_bedrock_on_aws_creds(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Bedrock judges bypass the LLM gateway, so the panel builder must gate
    them on AWS credentials — not on gateway API keys (which they don't use).
    Without creds the judge is skipped loudly, never half-configured."""
    monkeypatch.setenv(
        "JUDGE_MODELS", "bedrock:us.mistral.pixtral-large-2502-v1:0"
    )
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "test-key")
    models = MultiModelScorer._default_models(gate_v2=True)
    assert [m["model"] for m in models] == [
        "bedrock:us.mistral.pixtral-large-2502-v1:0"
    ]

    monkeypatch.delenv("AWS_ACCESS_KEY_ID")
    monkeypatch.delenv("AWS_PROFILE", raising=False)
    assert MultiModelScorer._default_models(gate_v2=True) == []
