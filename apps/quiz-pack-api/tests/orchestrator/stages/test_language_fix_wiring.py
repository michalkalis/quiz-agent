"""Where the language fix runs in a customer pack, and that OFF changes nothing.

Why: saved questions never change, so the fix must run on each round's new
questions BEFORE they are persisted, never on a saved one; its counts must
land in the round's step_log entry so an order's fixes can be evaluated
later; and with ``PACK_LANGUAGE_FIX`` off the worker builds exactly the
pipeline it built before.
"""

from __future__ import annotations

from typing import Any

import pytest
from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.stages.language_fix import LanguageFixStage
from app.orchestrator.stages.topup import TopUpStage

from tests.orchestrator.stages.test_topup import (
    _CountingSink,
    _FakeGenStage,
    _FakePersistStage,
    _incremental_stage,
    _make_ctx,
)


class _FakeLanguageStage:
    name = "language_fix"

    def __init__(self) -> None:
        self.seen: list[tuple[int, int]] = []

    async def run(self, ctx: OrderContext, sink: Any) -> StageResult:
        self.seen.append((ctx.locked_count, len(ctx.questions)))
        for q in ctx.questions[ctx.locked_count :]:
            q.question += " (fixed)"
        return StageResult(info={"checked": len(ctx.questions) - ctx.locked_count})


async def test_fix_runs_on_each_new_round_before_it_is_saved() -> None:
    lang = _FakeLanguageStage()
    persist = _FakePersistStage()
    sink = _CountingSink()
    ctx = _make_ctx(target_count=7, initial=0)

    await _incremental_stage(persist, _FakeGenStage(), language_stage=lang).run(
        ctx, sink
    )

    # Only the unsaved tail of each round: (locked, total) per round.
    assert lang.seen == [(0, 1), (1, 3), (3, 7)]
    # Every persisted question was fixed exactly once, before it was written.
    assert all(q.question.endswith("(fixed)") for b in persist.batches for q in b)
    assert not any(q.question.endswith("(fixed) (fixed)") for q in ctx.questions)
    rounds = [info for step, info in sink.steps if step == "round"]
    assert [r["language_fix"] for r in rounds] == [
        {"checked": 1},
        {"checked": 2},
        {"checked": 4},
    ]


async def test_without_the_fix_rounds_carry_no_language_info() -> None:
    sink = _CountingSink()
    await _incremental_stage(_FakePersistStage(), _FakeGenStage()).run(
        _make_ctx(target_count=3, initial=0), sink
    )
    assert all(
        "language_fix" not in info for step, info in sink.steps if step == "round"
    )


class _Store:
    async def get_embedding(self, *a, **kw):  # never called while building
        raise AssertionError


@pytest.mark.parametrize(
    "flag, expected", [(None, type(None)), ("1", LanguageFixStage)]
)
def test_worker_adds_the_fix_only_with_the_flag(
    flag: str | None, expected: type, monkeypatch: pytest.MonkeyPatch
) -> None:
    from app.worker.tasks import _build_stages

    if flag is None:
        monkeypatch.delenv("PACK_LANGUAGE_FIX", raising=False)
    else:
        monkeypatch.setenv("PACK_LANGUAGE_FIX", flag)
    monkeypatch.delenv("PACK_BATCH_SCHEDULE", raising=False)
    stages = _build_stages(
        {
            "generator": object(),
            "fact_verifier": object(),
            "scorer": object(),
            "question_store": _Store(),
            "fact_sourcer": object(),
            "session_factory": object(),
        }
    )
    topup = next(s for s in stages if isinstance(s, TopUpStage))
    assert type(topup._language_stage) is expected
