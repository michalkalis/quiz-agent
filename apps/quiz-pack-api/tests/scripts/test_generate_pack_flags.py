"""Tests for the 42.19 CLI flags on `scripts/generate_pack.py`.

Why these tests matter:
- `--out` files are the hand-off artifact for the Track F review loop
  (42.20 → 42.21 → 42.23 importer), so every dumped entry must round-trip
  through `Question.from_dict` and carry `review_status="pending_review"`.
- `--mcq-bias` only works if the steering text actually reaches the
  generator — the stub-stage test asserts on `ctx.prompt`, which is what
  `GenerationStage` hands to `AdvancedQuestionGenerator`.
- Invocations without the new flags must behave exactly as before
  (`order.prompt` byte-identical to `--prompt`, no out-file written).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.generation.pattern_routing import PATTERNS_TO_MCQ
from app.orchestrator.context import OrderContext, StageResult
from quiz_shared.models.question import Question

import scripts.generate_pack as generate_pack


def _make_question(**overrides) -> Question:
    data = {
        "id": "q-42-19-fixture",
        "question": "Is the Eiffel Tower taller in summer?",
        "type": "text_multichoice",
        "possible_answers": {"a": "True", "b": "False"},
        "correct_answer": "a",
        "topic": "Science",
        "category": "science",
        "difficulty": "medium",
        "source_url": "https://example.com/thermal-expansion",
    }
    data.update(overrides)
    return Question.from_dict(data)


class TestMcqBiasFlag:
    def test_bias_appends_steering_to_order_prompt(self):
        args = generate_pack._parse_args(
            ["--prompt", "history of flight", "--mcq-bias", "--dry-run"]
        )
        order = generate_pack._build_order(args)
        assert order.prompt.startswith("history of flight")
        assert order.prompt != "history of flight"
        # Every MCQ-routable pattern key must be named, so the LLM pins
        # `reasoning.pattern_used` to the exact snake_case keys 42.9a routes on.
        for pattern in PATTERNS_TO_MCQ:
            assert pattern in order.prompt

    def test_bias_sets_hard_quota_and_diversity_exemption(self):
        # 42.20 BLOCKER root cause B: a soft "prefer" footer lost to the
        # template's PATTERN DIVERSITY RULE (1/9 MCQ candidates). The footer
        # must carry a hard quota and the diversity-cap exemption keyed to
        # the carve-out wording in `_format_mcq_patterns_section`.
        args = generate_pack._parse_args(
            ["--prompt", "history of flight", "--mcq-bias", "--dry-run"]
        )
        order = generate_pack._build_order(args)
        assert "MULTIPLE-CHOICE EMPHASIS" in order.prompt
        assert "at least 7 of every 10" in order.prompt
        assert "EXEMPT from the PATTERN DIVERSITY RULE" in order.prompt

    def test_without_flag_prompt_is_byte_identical(self):
        args = generate_pack._parse_args(["--prompt", "history of flight", "--dry-run"])
        order = generate_pack._build_order(args)
        assert order.prompt == "history of flight"
        assert args.out is None


class TestNoCategoryPrompt:
    """#72 F-1: --prompt is no longer required. Omitting it yields an empty
    prompt, which produces no heuristic topic tokens → SourcingStage samples
    the curated TopicPool (no-category mode). A parser that still demanded
    --prompt would block that entry point entirely."""

    def test_prompt_optional_defaults_to_empty(self):
        args = generate_pack._parse_args(["--dry-run"])
        assert args.prompt == ""
        order = generate_pack._build_order(args)
        assert order.prompt == ""


class TestGenerationModeFlags:
    """#167 (D2): the CLI must be able to ask for a *grounded* run.

    `DIRECT_GENERATION` has been on by default since #166, and the only per-run
    lever was `--direct` — so an operator who needed the fact-sourced flow (the
    #167 entertainment pilot needs it: direct mode disables both attribution
    gates the post-cutoff filter joins on) had no way to say so without flipping
    a server-side env flag. `--grounded` is that lever, and it travels the same
    server-side `generation_mode` column as `--direct`, never as prompt text.
    """

    def test_grounded_flag_sets_generation_mode(self):
        args = generate_pack._parse_args(["--prompt", "pop culture", "--grounded"])
        assert generate_pack._build_order(args).generation_mode == "grounded"

        args = generate_pack._parse_args(["--prompt", "pop culture", "--direct"])
        assert generate_pack._build_order(args).generation_mode == "direct"

        # Neither flag → NULL, which inherits the server-side default. This is
        # the no-regression assert: every existing invocation is unchanged.
        args = generate_pack._parse_args(["--prompt", "pop culture"])
        assert generate_pack._build_order(args).generation_mode is None

    def test_direct_and_grounded_are_mutually_exclusive(self):
        """Asking for both is an operator mistake, not a silent precedence
        rule — argparse must reject it at parse time (exit 2) rather than let
        `--direct` quietly win and run the wrong pipeline on a paid batch."""
        with pytest.raises(SystemExit) as exc:
            generate_pack._parse_args(["--prompt", "x", "--direct", "--grounded"])
        assert exc.value.code == 2


class TestOutFlag:
    def test_write_out_round_trips_through_from_dict(self, tmp_path: Path):
        mcq = _make_question()
        plain = _make_question(
            id="q-42-19-plain",
            question="What is the capital of France?",
            type="text",
            possible_answers=None,
            correct_answer="Paris",
        )
        out = tmp_path / "mcq_batch_test.json"

        generate_pack._write_out([mcq, plain], str(out))

        entries = json.loads(out.read_text(encoding="utf-8"))
        assert len(entries) == 2
        assert all(e["review_status"] == "pending_review" for e in entries)
        restored = [Question.from_dict(e) for e in entries]
        assert restored[0].type == "text_multichoice"
        assert restored[0].possible_answers == {"a": "True", "b": "False"}
        assert restored[0].correct_answer == "a"
        assert restored[0].source_url == mcq.source_url
        assert restored[1].type == "text"
        assert restored[1].possible_answers is None
        assert [r.id for r in restored] == [mcq.id, plain.id]


class TestExpiryClassifierWiring:
    """#76 F-3b — the founder's manual replenishment pass (decision B: no new
    command) runs through this CLI's `_build_stages`, not the worker. If only
    the worker wired the expiry classifier, a manual current-tier pass would
    persist questions with NO `expires_at` — stale "this week's #1" rows the
    read-path filter could never drop. Pin both sides of the flag here.
    """

    @staticmethod
    def _generation_stage(monkeypatch):
        # Constructor-time env only (no network at build time): WebSearchSource
        # raises without TAVILY_API_KEY; the LLM stacks want OPENAI_API_KEY.
        monkeypatch.setenv("TAVILY_API_KEY", "tvly-test-placeholder")
        monkeypatch.setenv("OPENAI_API_KEY", "sk-test-placeholder")
        from app.orchestrator.stages import GenerationStage

        stages = generate_pack._build_stages(
            persist=False, dedup_store=generate_pack._NoopQuestionStore()
        )
        return next(s for s in stages if isinstance(s, GenerationStage))

    def test_flag_off_leaves_classifier_dormant(self, monkeypatch):
        monkeypatch.delenv("EXPIRY_CLASSIFICATION", raising=False)
        stage = self._generation_stage(monkeypatch)
        assert stage._expiry_classifier is None

    def test_flag_on_wires_classifier_into_cli_pipeline(self, monkeypatch):
        monkeypatch.setenv("EXPIRY_CLASSIFICATION", "1")
        stage = self._generation_stage(monkeypatch)
        assert stage._expiry_classifier is not None


class TestTopUpWiring:
    """2026-07-27 live-run F-b — the CLI omitted `TopUpStage`, so every pack
    that lost questions downstream just delivered short (the plain 100-question
    run needed 11 batches). The CLI must run the same top-up leg as the worker
    (`app/worker/tasks.py::_build_stages`), sharing the initial pass's stage
    instances, and it must sit after dedup (it re-runs dedup itself)."""

    def test_cli_pipeline_ends_with_topup_sharing_stage_instances(self, monkeypatch):
        monkeypatch.setenv("TAVILY_API_KEY", "tvly-test-placeholder")
        monkeypatch.setenv("OPENAI_API_KEY", "sk-test-placeholder")
        from app.orchestrator.stages import TopUpStage

        stages = generate_pack._build_stages(
            persist=False, dedup_store=generate_pack._NoopQuestionStore()
        )

        assert isinstance(stages[-1], TopUpStage)
        topup = stages[-1]
        names = [s.name for s in stages]
        assert names.index("topup") > names.index("dedup")
        # Same instances as the initial pass (#103 F5) — identical config,
        # so a top-up round behaves exactly like the first one.
        assert topup._generation_stage in stages
        assert topup._verification_stage in stages
        assert topup._scoring_stage in stages
        assert topup._dedup_stage in stages


class TestPerTopicCapFlag:
    """#167 — `--per-topic-cap` exists because the entertainment pilot burned
    ~$10 in an un-winnable top-up loop: 6 locked themes under CompositionStage's
    scaled cap of 2 can compose at most 12 questions, so `--target-count 30`
    left a shortfall no amount of regeneration could close, and every top-up
    round re-ran the paid judge/verify/score pipeline. The flag must reach the
    stage, and its absence must leave every other caller — above all the
    worker/API path, which never sets it — on today's scaled cap.
    """

    @staticmethod
    def _composition_stage(monkeypatch, **levers):
        monkeypatch.setenv("TAVILY_API_KEY", "tvly-test-placeholder")
        monkeypatch.setenv("OPENAI_API_KEY", "sk-test-placeholder")
        from app.orchestrator.stages import CompositionStage

        stages = generate_pack._build_stages(
            persist=False, dedup_store=generate_pack._NoopQuestionStore(), **levers
        )
        return next(s for s in stages if isinstance(s, CompositionStage))

    def test_flag_absent_leaves_scaled_cap(self, monkeypatch):
        args = generate_pack._parse_args(["--prompt", "pop culture", "--dry-run"])
        assert args.per_topic_cap is None
        assert self._composition_stage(monkeypatch)._per_topic_cap is None

    def test_flag_reaches_the_composition_stage(self, monkeypatch):
        args = generate_pack._parse_args(
            ["--prompt", "pop culture", "--per-topic-cap", "5", "--dry-run"]
        )
        assert args.per_topic_cap == 5
        stage = self._composition_stage(monkeypatch, per_topic_cap=args.per_topic_cap)
        assert stage._per_topic_cap == 5

    def test_override_also_reaches_the_topup_loop(self, monkeypatch):
        """TopUpStage re-applies composition to the full merged set after each
        round. If it held a *separate*, un-overridden CompositionStage, the
        override would be undone on the first top-up round — the exact loop
        this flag exists to stop."""
        from app.orchestrator.stages import TopUpStage

        monkeypatch.setenv("TAVILY_API_KEY", "tvly-test-placeholder")
        monkeypatch.setenv("OPENAI_API_KEY", "sk-test-placeholder")
        built = generate_pack._build_stages(
            persist=False,
            dedup_store=generate_pack._NoopQuestionStore(),
            per_topic_cap=5,
        )
        topup = next(s for s in built if isinstance(s, TopUpStage))
        assert topup._composition_stage._per_topic_cap == 5

    def test_app_path_composition_stage_is_unchanged(self):
        """The lever is CLI-only. A paid customer order must never inherit a
        loosened composition cap from an operator experiment, so the worker's
        own pipeline — and the top-up stage it feeds — must still build the
        stage with the scaled default (`None`)."""
        from app.orchestrator.stages import CompositionStage, TopUpStage
        from app.worker.tasks import _build_stages as build_worker_stages

        stages = build_worker_stages(
            {
                "generator": object(),
                "fact_verifier": object(),
                "scorer": object(),
                "question_store": object(),
                "fact_sourcer": object(),
                "session_factory": object(),
            }
        )
        composition = next(s for s in stages if isinstance(s, CompositionStage))
        topup = next(s for s in stages if isinstance(s, TopUpStage))
        assert composition._per_topic_cap is None
        assert topup._composition_stage is composition


class _StubSourcingStage:
    """Records the prompt the pipeline carries and emits one fixed question.

    Named ``sourcing`` to satisfy `PackGenerator.__init__`'s mandatory
    first-stage check; standing in for the whole pipeline keeps the test
    offline (no LLM clients constructed).
    """

    name = "sourcing"

    def __init__(self, questions: list[Question], seen: dict) -> None:
        self._questions = questions
        self._seen = seen

    async def run(self, ctx: OrderContext, sink) -> StageResult:
        self._seen["prompt"] = ctx.prompt
        self._seen["mcq_emphasis"] = ctx.mcq_emphasis
        ctx.questions.extend(self._questions)
        return StageResult()


class TestCliWiring:
    def test_dry_run_with_flags_writes_survivors_and_biases_pipeline_prompt(
        self, tmp_path: Path, monkeypatch
    ):
        question = _make_question()
        seen: dict = {}
        monkeypatch.setattr(
            generate_pack,
            "_build_stages",
            lambda *, persist, dedup_store, **_levers: [
                _StubSourcingStage([question], seen)
            ],
        )
        out = tmp_path / "mcq_batch_cli.json"

        exit_code = generate_pack.cli_main(
            [
                "--prompt",
                "space exploration",
                "--target-count",
                "1",
                "--dry-run",
                "--mcq-bias",
                "--out",
                str(out),
            ]
        )

        assert exit_code == 0
        # `ctx.prompt` is NOT handed to the generation LLM (42.20 blocker
        # root cause D) — the operative channel is `ctx.mcq_emphasis`,
        # derived by PackGenerator from the footer's marker and plumbed by
        # GenerationStage into the generator's hard-quota prompt section.
        assert "MULTIPLE-CHOICE EMPHASIS" in seen["prompt"]
        assert seen["mcq_emphasis"] is True
        assert seen["prompt"].startswith("space exploration")
        entries = json.loads(out.read_text(encoding="utf-8"))
        assert [e["id"] for e in entries] == [question.id]
        assert entries[0]["review_status"] == "pending_review"


class TestProdParityWiring:
    """#169 — the prod worker path is the source of truth; the CLI (used with
    ``LLM_GATEWAY=session``) must run the SAME stages/prompts, only the
    transport differs. Four defects were live before this locked them in: the
    CLI silently generated on the pre-#166 `v2_cot` template, dropped
    ScoringStage entirely under `--no-judges` (losing the deterministic craft
    and distractor gates prod keeps), never ran the answerability gate, and
    never wired the logical-consistency verifier. Each assert below pins one
    of those; a CLI batch that diverges here is not comparable to a paid pack.
    """

    @staticmethod
    def _stages(monkeypatch, **levers):
        # Constructor-time env only (no network at build time).
        monkeypatch.setenv("TAVILY_API_KEY", "tvly-test-placeholder")
        monkeypatch.setenv("OPENAI_API_KEY", "sk-test-placeholder")
        # Transport must not leak into a wiring test (test hermeticity).
        monkeypatch.setenv("LLM_GATEWAY", "direct")
        return generate_pack._build_stages(
            persist=False, dedup_store=generate_pack._NoopQuestionStore(), **levers
        )

    def test_generation_uses_feature_flag_prompt_version(self, monkeypatch):
        """worker.py and api/routes.py pass `generation_prompt_version()`; the
        CLI must read the same flag, not the ctor default `v2_cot`."""
        from app import feature_flags
        from app.orchestrator.stages import GenerationStage

        monkeypatch.delenv("GEN_PROMPT_VERSION", raising=False)
        generation = next(
            s for s in self._stages(monkeypatch) if isinstance(s, GenerationStage)
        )
        assert generation._generator.prompt_version == "direct_v1"
        assert (
            generation._generator.prompt_version
            == feature_flags.generation_prompt_version()
        )

        # The rollback lever must reach the CLI too.
        monkeypatch.setenv("GEN_PROMPT_VERSION", "v2_cot")
        generation = next(
            s for s in self._stages(monkeypatch) if isinstance(s, GenerationStage)
        )
        assert generation._generator.prompt_version == "v2_cot"

    def test_no_judges_keeps_scoring_stage_with_no_panel(self, monkeypatch):
        """Prod with `JUDGE_GATE=0` runs `ScoringStage(None)` — judges off,
        deterministic gates on. Omitting the stage (the old CLI behaviour)
        also dropped those gates, so a session run shipped questions prod
        would have rejected."""
        from app.orchestrator.stages import ScoringStage, TopUpStage

        stages = self._stages(monkeypatch, judges=False)
        scoring = [s for s in stages if isinstance(s, ScoringStage)]
        assert len(scoring) == 1
        assert scoring[0]._scorer is None
        # Top-up reuses that same instance, as the worker does — not a
        # stand-in that skips the gates on every backfill round.
        topup = next(s for s in stages if isinstance(s, TopUpStage))
        assert topup._scoring_stage is scoring[0]

    def test_judges_on_wires_the_panel(self, monkeypatch):
        from app.orchestrator.stages import ScoringStage

        scoring = next(
            s
            for s in self._stages(monkeypatch, judges=True)
            if isinstance(s, ScoringStage)
        )
        assert scoring._scorer is not None

    def test_answerability_stage_wired_by_default_and_into_topup(self, monkeypatch):
        """`answerability_check()` is True by default (#135 D10), so prod runs
        the early gate; the CLI had no such stage at all — neither in the main
        walk nor in top-up."""
        from app.orchestrator.stages import (
            AnswerabilityStage,
            DedupStage,
            TopUpStage,
            VerificationStage,
        )

        monkeypatch.delenv("ANSWERABILITY_CHECK", raising=False)
        stages = self._stages(monkeypatch)
        answerability = next(s for s in stages if isinstance(s, AnswerabilityStage))
        # EARLY: after dedup, before verification — an unclear question must
        # not pay for search or judges (worker `_build_stages` ordering).
        dedup_i = stages.index(next(s for s in stages if isinstance(s, DedupStage)))
        verify_i = stages.index(
            next(s for s in stages if isinstance(s, VerificationStage))
        )
        assert dedup_i < stages.index(answerability) < verify_i
        assert [s.name for s in stages].count("answerability") == 1
        topup = next(s for s in stages if isinstance(s, TopUpStage))
        assert topup._answerability_stage is answerability

    def test_answerability_flag_off_removes_the_stage(self, monkeypatch):
        from app.orchestrator.stages import AnswerabilityStage, TopUpStage

        monkeypatch.setenv("ANSWERABILITY_CHECK", "0")
        stages = self._stages(monkeypatch)
        assert not any(isinstance(s, AnswerabilityStage) for s in stages)
        topup = next(s for s in stages if isinstance(s, TopUpStage))
        assert topup._answerability_stage is None

    def test_logical_verifier_wired(self, monkeypatch):
        """46.B6: lateral puzzles divert to the consistency judge only when one
        is wired. Unwired, the CLI verified them on the factual path."""
        from app.orchestrator.stages import VerificationStage
        from app.verification.logical_verifier import LogicalConsistencyVerifier

        verification = next(
            s for s in self._stages(monkeypatch) if isinstance(s, VerificationStage)
        )
        assert isinstance(verification._logical_verifier, LogicalConsistencyVerifier)
