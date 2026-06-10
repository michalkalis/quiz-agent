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

    def test_without_flag_prompt_is_byte_identical(self):
        args = generate_pack._parse_args(["--prompt", "history of flight", "--dry-run"])
        order = generate_pack._build_order(args)
        assert order.prompt == "history of flight"
        assert args.out is None


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
            lambda *, persist: [_StubSourcingStage([question], seen)],
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
        # `ctx.prompt` is what GenerationStage passes to the generator —
        # the bias text being here means the generator receives it.
        assert "multiple-choice" in seen["prompt"]
        assert seen["prompt"].startswith("space exploration")
        entries = json.loads(out.read_text(encoding="utf-8"))
        assert [e["id"] for e in entries] == [question.id]
        assert entries[0]["review_status"] == "pending_review"
