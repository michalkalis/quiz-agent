"""#196 (track 196.3): the answer grader and the intent classifier run on
Claude Haiku 5.5 — and the switch must never cost a player a verdict.

Why each test exists:
- The eval (docs/testing/runs/haiku-eval-2026-10-10) measured Haiku with the
  SAME prompts; a prompt that drifts on the Claude path invalidates that
  result, so the prompt sent to Claude must equal the one sent to OpenAI.
- Haiku 5.5 answers ``temperature`` with a 400. Sending it would turn every
  answer into a fallback (or, without one, a "say it again").
- Any Anthropic failure (no key, error, overload, timeout, refusal, empty
  reply) must grade the answer on today's gpt-4o-mini path instead of failing.
- ``EVAL_MODEL`` / ``PARSE_MODEL`` are the rollback lever: set to
  gpt-4o-mini, Claude must not be called at all.
"""

from __future__ import annotations

import asyncio
import logging
import os
from types import SimpleNamespace

os.environ.setdefault("OPENAI_API_KEY", "sk-test")

import pytest
from app import hot_path_llm
from app.evaluation.evaluator import AnswerEvaluator
from app.input.parser import InputParser
from app.quiz.errors import JudgeUnavailable
from quiz_shared.models.question import Question

pytestmark = pytest.mark.asyncio

# The kind of voice answers the eval showed Haiku grading fairly where
# gpt-4o-mini said "incorrect" (recogniser respelling, Slovak genitive).
LENIENT = [
    ("Venecuela", "Venezuela", "sk"),
    ("Bratislavy", "Bratislava", "sk"),
    ("shakes beer", "William Shakespeare", "en"),
]


def _question(answer: str, language: str = "en") -> Question:
    return Question(
        id="q_haiku",
        question="Which one?",
        type="text",
        correct_answer=answer,
        topic="t",
        category="general",
        difficulty="medium",
        language=language,
    )


def _claude_reply(text: str, stop_reason: str = "end_turn"):
    return SimpleNamespace(
        content=[
            SimpleNamespace(type="thinking", thinking=""),
            SimpleNamespace(type="text", text=text),
        ],
        stop_reason=stop_reason,
    )


class FakeAnthropic:
    def __init__(self, behaviour):
        self.sent: list[dict] = []
        self._behaviour = behaviour
        self.messages = SimpleNamespace(create=self._create)

    async def _create(self, **kwargs):
        self.sent.append(kwargs)
        return await self._behaviour()


class FakeOpenAI:
    def __init__(self, text: str):
        self.sent: list[dict] = []
        self._text = text
        self.chat = SimpleNamespace(completions=SimpleNamespace(create=self._create))

    async def _create(self, **kwargs):
        self.sent.append(kwargs)
        message = SimpleNamespace(content=self._text)
        return SimpleNamespace(choices=[SimpleNamespace(message=message)])


@pytest.fixture(autouse=True)
def _isolated(monkeypatch):
    monkeypatch.setattr(hot_path_llm, "_fallback_warned", set())
    monkeypatch.setattr(hot_path_llm, "_anthropic_llm", None)
    monkeypatch.delenv("EVAL_MODEL", raising=False)
    monkeypatch.delenv("PARSE_MODEL", raising=False)
    monkeypatch.setenv("LLM_GATEWAY", "direct")


def _with_claude(monkeypatch, behaviour) -> FakeAnthropic:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-test")
    fake = FakeAnthropic(behaviour)
    monkeypatch.setattr(hot_path_llm, "_anthropic_llm", fake)
    return fake


def _replying(text: str, stop_reason: str = "end_turn"):
    async def behaviour():
        return _claude_reply(text, stop_reason)

    return behaviour


def _raising(exc: Exception):
    async def behaviour():
        raise exc

    return behaviour


# ── Routing ──────────────────────────────────────────────────────────────────


async def test_both_roles_default_to_haiku():
    assert AnswerEvaluator().model == "claude-haiku-5-5"
    assert InputParser().model == "claude-haiku-5-5"


@pytest.mark.parametrize("heard,answer,lang", LENIENT)
async def test_grader_runs_on_haiku_with_the_unchanged_prompt(
    monkeypatch, heard, answer, lang
):
    """Same prompt as the OpenAI path (what the eval measured), no temperature,
    effort low, and Claude's verdict is the one that scores."""
    question = _question(answer, lang)

    # Reference: the request today's path sends (no key → gpt-4o-mini).
    monkeypatch.setenv("ANTHROPIC_API_KEY", "")
    reference = AnswerEvaluator()
    reference.client = FakeOpenAI("incorrect")
    await reference.evaluate(heard, question)
    openai_messages = reference.client.sent[0]["messages"]

    claude = _with_claude(monkeypatch, _replying("correct"))
    evaluator = AnswerEvaluator()
    evaluator.client = FakeOpenAI("incorrect")  # must not be used

    assert await evaluator.evaluate(heard, question) == ("correct", 1.0)
    assert evaluator.client.sent == []
    sent = claude.sent[0]
    assert sent["model"] == "claude-haiku-5-5"
    assert "temperature" not in sent
    assert sent["output_config"] == {"effort": "low"}
    assert sent["system"] == openai_messages[0]["content"]
    assert sent["messages"] == openai_messages[1:]


async def test_parser_runs_on_haiku(monkeypatch):
    claude = _with_claude(
        monkeypatch,
        _replying(
            '{"intents": [{"intent_type": "answer", "extracted_data": {"answer": "Jupiter"}}]}'
        ),
    )
    parser = InputParser()
    parser.client = FakeOpenAI("{}")

    intents = await parser.parse(
        "no tak to bude asi ten Jupiter", "Ktorá planéta?", "asking"
    )

    assert intents[0]["extracted_data"]["answer"] == "Jupiter"
    assert parser.client.sent == []
    assert "temperature" not in claude.sent[0]


# ── Fail-safe ────────────────────────────────────────────────────────────────


async def _hang():
    await asyncio.sleep(30)


@pytest.mark.parametrize(
    "behaviour",
    [
        _raising(RuntimeError("overloaded_error")),
        _raising(ConnectionError("reset")),
        _hang,
        _replying("", "end_turn"),
        _replying("correct", "refusal"),
        _replying("corr", "max_tokens"),
    ],
    ids=["api-error", "network", "timeout", "empty", "refusal", "truncated"],
)
async def test_any_claude_failure_grades_on_gpt_4o_mini(monkeypatch, behaviour):
    """The player gets today's verdict, not an error and not a guess."""
    monkeypatch.setattr(hot_path_llm, "CLAUDE_TIMEOUT_S", 0.05)
    claude = _with_claude(monkeypatch, behaviour)
    evaluator = AnswerEvaluator()
    evaluator.client = FakeOpenAI("correct")

    assert await evaluator.evaluate("Venecuela", _question("Venezuela", "sk")) == (
        "correct",
        1.0,
    )
    assert len(claude.sent) == 1
    fallback = evaluator.client.sent[0]
    assert fallback["model"] == "gpt-4o-mini"
    assert fallback["temperature"] == 0.3


async def test_no_key_never_calls_claude(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "")
    claude = FakeAnthropic(_replying("correct"))
    monkeypatch.setattr(hot_path_llm, "_anthropic_llm", claude)
    parser = InputParser()
    parser.client = FakeOpenAI('{"intents": [{"intent_type": "skip"}]}')

    intents = await parser.parse("neviem, preskoč túto otázku", "Otázka?", "asking")

    assert intents[0]["intent_type"] == "skip"
    assert claude.sent == []
    assert parser.client.sent[0]["model"] == "gpt-4o-mini"


async def test_fallback_warns_once_not_per_answer(monkeypatch, caplog):
    _with_claude(monkeypatch, _raising(RuntimeError("down")))
    evaluator = AnswerEvaluator()
    evaluator.client = FakeOpenAI("incorrect")

    with caplog.at_level(logging.WARNING, logger=hot_path_llm.__name__):
        for _ in range(3):
            await evaluator.evaluate("Kolumbia", _question("Venezuela", "sk"))

    assert len([r for r in caplog.records if "using gpt-4o-mini" in r.message]) == 1


# ── Rollback lever ───────────────────────────────────────────────────────────


async def test_env_rolls_a_role_back_to_gpt_4o_mini(monkeypatch):
    claude = _with_claude(monkeypatch, _replying("correct"))
    monkeypatch.setenv("EVAL_MODEL", "gpt-4o-mini")
    evaluator = AnswerEvaluator()
    evaluator.client = FakeOpenAI("incorrect")

    assert await evaluator.evaluate("Kolumbia", _question("Venezuela", "sk")) == (
        "incorrect",
        0.0,
    )
    assert claude.sent == []
    assert InputParser().model == "claude-haiku-5-5"  # roles switch independently


# ── One deadline per call (review on #331) ───────────────────────────────────


async def test_claude_try_leaves_the_fallback_room_inside_one_call_budget():
    """The module's invariant: one call ≤ CALL_BUDGET_S, so parse + evaluate
    stays ≤ 24 s, inside iOS's 30 s submit timeout. The Claude try must leave
    the fallback enough of that budget to answer (gpt-4o-mini p95 ≈ 3 s)."""
    assert 2 * hot_path_llm.CALL_BUDGET_S <= 24
    assert hot_path_llm.CALL_BUDGET_S - hot_path_llm.CLAUDE_TIMEOUT_S >= 5


def _openai_create(create):
    return SimpleNamespace(
        chat=SimpleNamespace(completions=SimpleNamespace(create=create))
    )


async def _hang_openai(**kwargs):
    await asyncio.sleep(30)


async def test_claude_and_fallback_share_one_deadline(monkeypatch):
    """Claude hangs, then the fallback hangs: the call still ends at
    CALL_BUDGET_S, not CLAUDE_TIMEOUT_S + CALL_BUDGET_S."""
    monkeypatch.setattr(hot_path_llm, "CALL_BUDGET_S", 0.3)
    monkeypatch.setattr(hot_path_llm, "CLAUDE_TIMEOUT_S", 0.2)
    _with_claude(monkeypatch, _hang)
    evaluator = AnswerEvaluator()
    evaluator.client = _openai_create(_hang_openai)
    loop = asyncio.get_running_loop()
    started = loop.time()

    with pytest.raises(JudgeUnavailable):
        await evaluator.evaluate("Kolumbia", _question("Venezuela", "sk"))

    assert loop.time() - started < 0.4


async def test_two_call_submit_worst_case_is_two_call_budgets(monkeypatch):
    """The documented worst case, scaled down: a classifier whose Claude try
    times out and whose fallback answers just before the deadline, then a
    judge that is down on both providers — ≤ 2 × CALL_BUDGET_S in total
    (24 s at full scale), never Claude + fallback per call (40 s)."""
    budget = 0.3
    monkeypatch.setattr(hot_path_llm, "CALL_BUDGET_S", budget)
    monkeypatch.setattr(hot_path_llm, "CLAUDE_TIMEOUT_S", 0.2)
    _with_claude(monkeypatch, _hang)

    async def _late_answer(**kwargs):
        await asyncio.sleep(0.08)
        content = (
            '{"intents": [{"intent_type": "answer", '
            '"extracted_data": {"answer": "Kolumbia"}}]}'
        )
        message = SimpleNamespace(content=content)
        return SimpleNamespace(choices=[SimpleNamespace(message=message)])

    parser, evaluator = InputParser(), AnswerEvaluator()
    parser.client = _openai_create(_late_answer)
    evaluator.client = _openai_create(_hang_openai)
    loop = asyncio.get_running_loop()
    started = loop.time()

    intents = await parser.parse("hmm asi to bude Kolumbia", "Ktorá krajina?", "asking")
    with pytest.raises(JudgeUnavailable):
        await evaluator.evaluate(
            intents[0]["extracted_data"]["answer"], _question("Venezuela", "sk")
        )

    assert loop.time() - started < 2 * budget + 0.1


# ── Injected Claude client (eval harness seam, review on #331) ───────────────


async def test_an_injected_claude_client_is_the_one_called(monkeypatch):
    """The eval harness measures real Claude latency/cost by injecting its
    recorder; the shared client must not bypass it."""
    shared = _with_claude(monkeypatch, _replying("incorrect"))
    injected = FakeAnthropic(_replying("correct"))
    evaluator = AnswerEvaluator()
    evaluator.client = FakeOpenAI("incorrect")
    evaluator.claude_client = injected

    result = await evaluator.evaluate("Venecuela", _question("Venezuela", "sk"))

    assert result == ("correct", 1.0)
    assert len(injected.sent) == 1
    assert shared.sent == []


async def test_eval_harness_records_claude_calls_per_effort_arm(monkeypatch):
    """scripts/eval_hot_path_models.py: a Claude arm must see every Claude
    call (latency, tokens → spend cap) and its effort suffix must reach the
    request, otherwise @medium and @low silently measure the same thing."""
    import importlib.util

    import anthropic

    class _FakeAsyncAnthropic:
        def __init__(self, **kwargs):
            self.sent: list[dict] = []
            self.messages = SimpleNamespace(create=self._create)

        async def _create(self, **request):
            self.sent.append(request)
            reply = _claude_reply("correct")
            reply.usage = SimpleNamespace(input_tokens=1000, output_tokens=20)
            return reply

    monkeypatch.setattr(anthropic, "AsyncAnthropic", _FakeAsyncAnthropic)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-test")
    path = os.path.join(
        os.path.dirname(__file__), "..", "scripts", "eval_hot_path_models.py"
    )
    spec = importlib.util.spec_from_file_location("eval_hot_path_models", path)
    harness = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(harness)

    for effort in ("medium", "low"):
        rec = harness.make_recorder(f"claude-haiku-5-5@{effort}")
        evaluator = AnswerEvaluator(model="claude-haiku-5-5")
        harness.attach(rec, evaluator)

        result = await evaluator.evaluate("Venecuela", _question("Venezuela", "sk"))

        assert result == ("correct", 1.0)
        assert len(rec.calls) == 1
        assert rec._anthropic.sent[0]["output_config"] == {"effort": effort}
        assert rec.spend() > 0
