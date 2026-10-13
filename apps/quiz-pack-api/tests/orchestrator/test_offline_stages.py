"""`app.orchestrator.offline_stages` — one definition of the offline stage walk (#170 D5, #202).

Why: the weekly fresh-topup (#202) builds its pipeline from the same function
the corpus CLI uses, so (a) the move out of the scripts must not change what a
default CLI run assembles, and (b) the two new pins must actually pin — a
scheduled run that silently drew the GEN_ALT model or a different answerability
model would not match the quality bar its sample runs were judged on.
"""

from __future__ import annotations

import pytest
import scripts.generate_pack as generate_pack
import scripts.replay_dedup_json as replay_dedup_json
from app.orchestrator import offline_stages
from app.orchestrator.stages import (
    AnswerabilityStage,
    CompositionStage,
    GenerationStage,
    PersistStage,
    ScoringStage,
    SourcingStage,
    TopUpStage,
    VerificationStage,
)
from app.orchestrator.stages.dedup import DedupStage
from quiz_shared.llm import factory as llm_factory


class _NoDuplicates:
    async def find_duplicates(self, question_text, threshold=0.85):
        return []


@pytest.fixture(autouse=True)
def _hermetic_env(monkeypatch):
    # Constructor-time env only (no network at build time).
    monkeypatch.setenv("TAVILY_API_KEY", "tvly-test-placeholder")
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test-placeholder")
    monkeypatch.setenv("LLM_GATEWAY", "direct")
    for name in ("GENERATION_MODEL", "ANSWERABILITY_MODEL", "ANSWERABILITY_CHECK"):
        monkeypatch.delenv(name, raising=False)


def _build(**kw):
    return offline_stages.build_stages(
        persist=kw.pop("persist", False), dedup_store=_NoDuplicates(), **kw
    )


def test_scripts_use_the_single_definition() -> None:
    """#170 D5: one definition. The script names are aliases, not forks."""
    assert generate_pack._build_stages is offline_stages.build_stages
    assert generate_pack._build_order is offline_stages.build_order
    assert replay_dedup_json.build_dedup_stage is offline_stages.build_dedup_stage
    assert replay_dedup_json.build_strictness is offline_stages.build_strictness


def test_default_dry_run_walk_is_unchanged() -> None:
    """The CLI's direct dry-run walk, class for class, in order — a reorder
    here would change what every corpus batch is gated by."""
    stages = _build()
    assert [type(s) for s in stages] == [
        SourcingStage,
        GenerationStage,
        DedupStage,
        AnswerabilityStage,  # ANSWERABILITY_CHECK defaults ON (#135 D10)
        VerificationStage,
        ScoringStage,
        CompositionStage,
        TopUpStage,
    ]
    assert not any(isinstance(s, PersistStage) for s in stages)


def test_persist_true_appends_persist_stage_last() -> None:
    stages = _build(persist=True)
    assert isinstance(stages[-1], PersistStage)
    assert [type(s) for s in stages[:-1]] == [type(s) for s in _build()]


def test_answerability_flag_off_removes_the_stage(monkeypatch) -> None:
    monkeypatch.setenv("ANSWERABILITY_CHECK", "0")
    assert not any(isinstance(s, AnswerabilityStage) for s in _build())


def test_generation_model_pin_beats_the_alt_mix_and_the_env_flag(monkeypatch) -> None:
    """Without the pin, GEN_ALT_SHARE=1 always draws the alt model and
    GENERATION_MODEL wins over the draw; with it, neither may leak in."""
    monkeypatch.setattr(llm_factory, "GEN_ALT", "alt-model")
    monkeypatch.setattr(llm_factory, "GEN_ALT_SHARE", 1.0)

    def generator(**kw):
        stage = next(s for s in _build(**kw) if isinstance(s, GenerationStage))
        return stage._generator.generation_model

    assert generator() == "alt-model"  # today's behaviour, untouched
    monkeypatch.setenv("GENERATION_MODEL", "env-model")
    assert generator() == "env-model"
    assert generator(generation_model="pinned-model") == "pinned-model"


def test_answerability_model_is_passed_only_when_given(monkeypatch) -> None:
    def checker_model(**kw):
        stage = next(s for s in _build(**kw) if isinstance(s, AnswerabilityStage))
        return stage._checker._model

    default = checker_model()
    assert default == llm_factory.ANSWERABILITY
    assert checker_model(answerability_model="claude-haiku-5-5") == "claude-haiku-5-5"
    monkeypatch.setenv("ANSWERABILITY_MODEL", "env-model")
    assert checker_model() == "env-model"  # env flag still applies when unpinned
    assert checker_model(answerability_model="claude-sonnet-5-5") == "claude-sonnet-5-5"


def test_topup_and_dedup_share_one_strictness_object() -> None:
    stages = _build()
    dedup = next(s for s in stages if isinstance(s, DedupStage))
    topup = next(s for s in stages if isinstance(s, TopUpStage))
    assert topup._strictness is dedup._strictness
