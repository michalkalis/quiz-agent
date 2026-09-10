"""Importer gates on `scripts/import_questions_json.py`: #158 guard + #177 auto.

The gen-review 2026-08-09 part-4 verdict: an unverified/held question never
enters the corpus. The importer used to stamp EVERY row with the requested
`--review-status` (then defaulting to `approved`) without ever reading
`generation_metadata.extra` — so a question the verifier held (or explicitly
failed) could be batch-imported straight into the served corpus. These tests
pin the guard: held/failed rows are rejected loudly, clean and hand-curated
rows still import.

The second half pins #177 (founder 2026-09-10): review status is now decided
per row, so a clean EN row with a source becomes `approved` with a machine
marker while anything short of that stays `pending_review`. The #158 guard runs
FIRST — "held" still means "does not enter", whatever the approval predicate
would say.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import scripts.import_questions_json as importer
from app.scoring.machine_approval import GATE_VERSION
from scripts.import_questions_json import AUTO_REVIEW_STATUS, _load_questions


def _row(qid: str, extra: dict | None = None) -> dict:
    row: dict = {
        "id": qid,
        "question": f"stub question {qid}",
        "correct_answer": "answer",
        "topic": "General",
        "category": "general",
        "difficulty": "medium",
    }
    if extra is not None:
        row["generation_metadata"] = {"extra": extra}
    return row


def _write(tmp_path: Path, rows: list[dict]) -> Path:
    path = tmp_path / "batch.json"
    path.write_text(json.dumps(rows))
    return path


def test_held_for_review_row_is_rejected(tmp_path: Path) -> None:
    path = _write(
        tmp_path,
        [
            _row("q_clean", {"verified": True, "verification_score": 0.9}),
            _row("q_held", {"verified": False, "held_for_review": True}),
        ],
    )
    loaded = _load_questions([path], "approved")
    assert {q.id for q in loaded} == {"q_clean"}


def test_verification_failed_row_is_rejected(tmp_path: Path) -> None:
    path = _write(tmp_path, [_row("q_failed", {"verified": False})])
    assert _load_questions([path], "approved") == []


def test_rejection_is_independent_of_review_status(tmp_path: Path) -> None:
    # Even importing as pending_review must not smuggle a held row in — the
    # corpus has no review queue; "held" means "does not enter", full stop.
    path = _write(tmp_path, [_row("q_held", {"held_for_review": True})])
    assert _load_questions([path], "pending_review") == []


def test_hand_curated_row_without_pipeline_provenance_imports(tmp_path: Path) -> None:
    # No generation_metadata at all (hand-written corpus content that never
    # ran the pipeline) — the guard targets pipeline provenance only.
    path = _write(tmp_path, [_row("q_manual")])
    loaded = _load_questions([path], "approved")
    assert [q.id for q in loaded] == ["q_manual"]


def test_cli_default_review_status_is_auto(monkeypatch, tmp_path: Path) -> None:
    """#177 (founder 2026-09-10): the default is the per-row decision, not one
    status for the batch. A batch imported without an explicit verdict must NOT
    be force-stamped — every row is judged on its own gate evidence.
    """
    path = _write(tmp_path, [_row("q_clean", {"verified": True})])
    captured: dict[str, str] = {}

    async def _fake_run(args) -> int:
        captured["review_status"] = args.review_status
        return 0

    monkeypatch.setattr(importer, "_run", _fake_run)
    monkeypatch.setattr(sys, "argv", ["import_questions_json.py", "--json-path", str(path)])

    assert importer.main() == 0
    assert captured["review_status"] == AUTO_REVIEW_STATUS


# --- #177 per-row machine approval -------------------------------------------
#
# Why these scenarios: `approved` is served to every client, App Store
# included. Auto mode is the only path that can produce it without a human, so
# each test below pins one half of the rule — a clean EN row earns it AND
# carries a machine marker, and a row with any finding (or missing evidence)
# does not.


def _clean_row(qid: str = "q_auto", **overrides) -> dict:
    row = _row(
        qid,
        {"verified": True, "verification_score": 0.9, "factcheck_tier": "web"},
    )
    row["question"] = "Which planet in our solar system spins fastest on its axis?"
    row["correct_answer"] = "Jupiter"
    row["language"] = "en"
    row["source_url"] = "https://en.wikipedia.org/wiki/Jupiter"
    row.update(overrides)
    return row


def test_auto_mode_approves_a_clean_english_row(tmp_path: Path) -> None:
    """The founder's new rule in one assertion: gates clean → `approved`, and
    `reviewed_by` says a machine (not the founder) vouched for it, so the
    corpus stays auditable."""
    path = _write(tmp_path, [_clean_row()])

    loaded = _load_questions([path], AUTO_REVIEW_STATUS)

    assert [q.review_status for q in loaded] == ["approved"]
    assert loaded[0].reviewed_by == GATE_VERSION
    assert loaded[0].reviewed_at is not None


def test_auto_mode_keeps_a_row_without_a_source_pending(tmp_path: Path) -> None:
    """Source mandatory (founder 2026-09-09): no `source_url`, no approval —
    and no machine marker either, so a human verdict is still pending."""
    path = _write(tmp_path, [_clean_row(source_url=None)])

    loaded = _load_questions([path], AUTO_REVIEW_STATUS)

    assert [q.review_status for q in loaded] == ["pending_review"]
    assert loaded[0].reviewed_by is None


def test_auto_mode_keeps_a_flagged_row_pending(tmp_path: Path) -> None:
    """A persisted shadow finding (#177 T1) is the whole signal the rule turns
    on: flagged-but-kept rows stay TestFlight-only."""
    flagged = _clean_row()
    flagged["generation_metadata"]["extra"]["craft_flag"] = "stem_leak(jupiter)"
    path = _write(tmp_path, [flagged])

    loaded = _load_questions([path], AUTO_REVIEW_STATUS)

    assert [q.review_status for q in loaded] == ["pending_review"]


def test_explicit_status_still_forces_every_row(tmp_path: Path) -> None:
    """The human paths must stay absolute: `--review-status pending_review`
    quarantines even a row the machine would have approved (and `approved`
    remains the founder's promotion lever)."""
    path = _write(tmp_path, [_clean_row()])

    forced = _load_questions([path], "pending_review")

    assert [q.review_status for q in forced] == ["pending_review"]
    assert forced[0].reviewed_by is None
