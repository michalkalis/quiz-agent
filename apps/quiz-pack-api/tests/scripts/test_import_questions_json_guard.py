"""#158 fail-closed corpus guard on `scripts/import_questions_json.py`.

The gen-review 2026-08-09 part-4 verdict: an unverified/held question never
enters the corpus. The importer used to stamp EVERY row with the requested
`--review-status` (default `approved`) without ever reading
`generation_metadata.extra` — so a question the verifier held (or explicitly
failed) could be batch-imported straight into the served corpus. These tests
pin the guard: held/failed rows are rejected loudly, clean and hand-curated
rows still import.
"""

from __future__ import annotations

import json
from pathlib import Path

from scripts.import_questions_json import _load_questions


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
