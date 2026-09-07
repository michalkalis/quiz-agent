"""#170 170.14b — `scripts/replay_dedup_json.py` (A16b).

Why: Sessions J and K re-measure dedup decisions over SAVED candidates. The
harness is only trustworthy if (a) the same input under the same switches
reproduces the original `DedupStage` run decision for decision, (b) it never
generates anything — a single generator call would make a "replay" a new
sample — and (c) it refuses to run without a corpus, because a noop store
would silently measure in-batch duplicates only.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import pytest
import scripts.replay_dedup_json as harness
from quiz_shared.models.question import Question


class _FakeStore:
    """`find_duplicates` double keyed by question text; counts every call."""

    def __init__(self, canned: dict[str, list[tuple[Question, float]]]) -> None:
        self._canned = canned
        self.calls = 0

    async def find_duplicates(
        self, question_text: str, threshold: float = 0.85
    ) -> list[tuple[Question, float]]:
        self.calls += 1
        return [(q, s) for q, s in self._canned.get(question_text, []) if s >= threshold]


def _row(qid: str, text: str, answer: str = "Saturn", category: str = "science-nature") -> dict:
    return {
        "id": qid,
        "question": text,
        "correct_answer": answer,
        "topic": "Space",
        "category": category,
        "difficulty": "medium",
    }


CORPUS = Question.from_dict(_row("corpus_1", "Which planet has the most moons?"))
ROWS = [
    _row("c_dup", "Which planet has the most moons?"),  # cosine 0.95 → cosine drop
    _row("c_gray", "Which planet is orbited by the most moons?"),  # 0.78 → passes (no judge)
    _row("c_new", "Which river flows through Vienna?", "Danube", "travel-places"),
    _row("c_repeat", "Which river flows through Vienna?", "Danube", "travel-places"),  # in-batch
]
CANNED = {
    ROWS[0]["question"]: [(CORPUS, 0.95)],
    ROWS[1]["question"]: [(CORPUS, 0.78)],
}


def _write(tmp_path: Path) -> Path:
    path = tmp_path / "candidates.json"
    path.write_text(json.dumps(ROWS))
    return path


def _args(path: Path, out: Path, dedup_store: str = "pgvector") -> argparse.Namespace:
    return argparse.Namespace(
        json_path=[str(path)],
        dedup_store=dedup_store,
        out=str(out),
        language="en",
        gold_standard=None,
        dry_run=True,
    )


@pytest.mark.asyncio
async def test_replay_reproduces_the_original_stage_decisions(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Same input + same switches ⇒ the same kept/dropped/reason per candidate
    as a direct `DedupStage` run, and the file carries the switches verbatim."""
    monkeypatch.delenv("DEDUP_GRAYZONE_JUDGE", raising=False)
    monkeypatch.setenv("DEDUP_STRICTNESS_PER_CATEGORY", "entertainment=cosine:0.92")
    path = _write(tmp_path)
    out = tmp_path / "replay.json"

    # The "original run": DedupStage composed the same way, over the same rows.
    original_store = _FakeStore(CANNED)
    original_stage = harness.build_dedup_stage(original_store)
    original_ctx = harness.OrderContext(
        order_id=harness.uuid.uuid4(), prompt="x", language="en", target_count=4
    )
    original_ctx.questions = [Question.from_dict(r) for r in ROWS]
    await original_stage.run(original_ctx, harness._NullSink())  # type: ignore[arg-type]
    expected = [
        (d["id"], d["kept"], d["reason"]) for d in original_stage.last_decisions
    ]
    assert expected == [
        ("c_dup", False, "cosine"),
        ("c_gray", True, None),
        ("c_new", True, None),
        ("c_repeat", False, "in_batch"),
    ]

    replay_store = _FakeStore(CANNED)
    assert await harness._run(_args(path, out), store=replay_store) == 0

    payload = json.loads(out.read_text())
    assert [(d["id"], d["kept"], d["reason"]) for d in payload["decisions"]] == expected
    assert payload["info"]["kept"] == 2 and payload["info"]["dropped"] == 2
    assert payload["env"]["DEDUP_STRICTNESS_PER_CATEGORY"] == "entertainment=cosine:0.92"
    assert payload["env"]["DEDUP_GRAYZONE_JUDGE"] is None
    assert replay_store.calls == original_store.calls


@pytest.mark.asyncio
async def test_replay_never_touches_the_generator(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """A replay is only a replay if nothing new is generated: constructing the
    generator (or any generation stage) must be impossible during a run."""
    from app.generation import advanced_generator
    from app.orchestrator.stages import generation as generation_stage

    def _forbidden(*args, **kwargs):
        raise AssertionError("replay must not construct the generator")

    monkeypatch.setattr(advanced_generator.AdvancedQuestionGenerator, "__init__", _forbidden)
    monkeypatch.setattr(generation_stage.GenerationStage, "__init__", _forbidden)
    path = _write(tmp_path)

    assert await harness._run(_args(path, tmp_path / "r.json"), store=_FakeStore(CANNED)) == 0


@pytest.mark.asyncio
async def test_noop_store_is_refused_fail_loud(tmp_path: Path) -> None:
    """`--dedup-store noop` would measure in-batch only — refused before any
    work, even when a store is injected."""
    path = _write(tmp_path)
    with pytest.raises(SystemExit, match="refused"):
        await harness._run(_args(path, tmp_path / "r.json", dedup_store="noop"), store=_FakeStore({}))
    assert not (tmp_path / "r.json").exists()


def test_cli_defaults_to_pgvector_and_accepts_dry_run() -> None:
    args = harness.build_parser().parse_args(["--json-path", "x.json", "--dry-run"])
    assert args.dedup_store == "pgvector"
    assert args.dry_run is True
