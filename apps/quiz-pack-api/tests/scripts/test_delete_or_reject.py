"""Tests for ``scripts/delete_or_reject.py`` (Issue #42 task 42.3).

The cap check is the load-bearing invariant: if a misclassification ever
expanded the candidate set, we must refuse to mutate any file rather than
silently lose questions.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from scripts import delete_or_reject as dor


PROCEDURAL_ANSWER = (
    "Fill the 5-litre jug, pour into the 3-litre jug until full. "
    "Empty the 3-litre jug. Pour the remaining 2 litres into the 3-litre jug. "
    "Refill the 5-litre jug and top off the 3-litre jug to get 4 litres."
)


def _write_batch(tmp_path: Path, name: str, questions: list[dict]) -> Path:
    p = tmp_path / name
    p.write_text(json.dumps({"questions": questions}, indent=2))
    return p


def _file_questions(p: Path) -> list[dict]:
    return json.loads(p.read_text())["questions"]


class TestPlanFile:
    def test_procedural_is_scheduled_for_delete(self, tmp_path):
        p = _write_batch(tmp_path, "b.json", [
            {"id": "q1", "question": "Procedural?", "correct_answer": PROCEDURAL_ANSWER, "type": "text"},
            {"id": "q2", "question": "Short?", "correct_answer": "Yes", "type": "text"},
        ])
        plan = dor._plan_file(p)
        assert len(plan["deletes"]) == 1
        assert plan["deletes"][0]["index"] == 0
        assert plan["rejects"] == []

    def test_verbose_after_autofix_is_rejected(self, tmp_path):
        # 14 words, no em-dash so autofix can't shorten it.
        long_ans = "The text was printed on a physical surface and filmed with a camera"
        p = _write_batch(tmp_path, "b.json", [
            {"id": "q1", "question": "Why?", "correct_answer": long_ans, "type": "text"},
        ])
        plan = dor._plan_file(p)
        assert plan["deletes"] == []
        assert len(plan["rejects"]) == 1
        assert plan["rejects"][0]["word_count"] > dor.VERBOSE_LIMIT

    def test_em_dash_tail_autofixed_then_not_rejected(self, tmp_path):
        # After autofix the head ("Czech") is well under VERBOSE_LIMIT.
        p = _write_batch(tmp_path, "b.json", [
            {"id": "q1", "question": "Lang?",
             "correct_answer": "Czech — 'robota' means forced labour",
             "type": "text"},
        ])
        plan = dor._plan_file(p)
        assert plan["deletes"] == []
        assert plan["rejects"] == []

    def test_no_mutation_during_plan(self, tmp_path):
        before = [{"id": "q1", "question": "X?",
                   "correct_answer": PROCEDURAL_ANSWER, "type": "text"}]
        p = _write_batch(tmp_path, "b.json", before)
        dor._plan_file(p)
        # File on disk must be byte-identical to the original.
        assert _file_questions(p) == before


class TestApplyAndCap:
    def test_apply_deletes_and_annotates(self, tmp_path):
        p = _write_batch(tmp_path, "b.json", [
            {"id": "q1", "question": "Procedural?", "correct_answer": PROCEDURAL_ANSWER, "type": "text"},
            {"id": "q2", "question": "Why?",
             "correct_answer": "The text was printed on a physical surface and filmed with a camera",
             "type": "text"},
            {"id": "q3", "question": "Short?", "correct_answer": "Yes", "type": "text"},
        ])
        plan = dor._plan_file(p)
        dor._apply_plan(plan)
        qs = _file_questions(p)
        # q1 (procedural) deleted; q2 annotated; q3 untouched.
        assert len(qs) == 2
        ids = [q["id"] for q in qs]
        assert "q1" not in ids
        rejected = [q for q in qs if q.get("review_status") == "rejected"]
        assert len(rejected) == 1
        assert rejected[0]["id"] == "q2"
        assert rejected[0]["rejection_reason"] == dor.REJECTION_REASON

    def test_idempotent(self, tmp_path):
        p = _write_batch(tmp_path, "b.json", [
            {"id": "q1", "question": "Procedural?", "correct_answer": PROCEDURAL_ANSWER, "type": "text"},
            {"id": "q2", "question": "Short?", "correct_answer": "Yes", "type": "text"},
        ])
        dor._apply_plan(dor._plan_file(p))
        first = p.read_text()
        # Second run finds nothing to do.
        plan2 = dor._plan_file(p)
        assert plan2["deletes"] == []
        assert plan2["rejects"] == []
        dor._apply_plan(plan2)
        assert p.read_text() == first

    def test_cap_check_blocks_over_limit(self, tmp_path):
        # 10 questions, 4 verbose -> 40% > 5% cap.
        long_ans = "The text was printed on a physical surface and filmed with a camera"
        qs = [{"id": f"q{i}", "question": "Q?", "correct_answer": long_ans, "type": "text"}
              for i in range(4)]
        qs += [{"id": f"q{i}", "question": "Q?", "correct_answer": "ok", "type": "text"}
               for i in range(6)]
        p = _write_batch(tmp_path, "b.json", qs)
        plans = [dor._plan_file(p)]
        n_del, n_rej, cap = dor.cap_check(plans, total_questions=10, cap_frac=0.05)
        assert n_rej == 4
        assert n_del == 0
        assert n_del + n_rej > cap


class TestMainEntrypoint:
    def test_main_fails_loud_over_cap(self, tmp_path, monkeypatch, capsys):
        long_ans = "The text was printed on a physical surface and filmed with a camera"
        big = [{"id": f"q{i}", "question": "Q?", "correct_answer": long_ans, "type": "text"}
               for i in range(5)]
        big += [{"id": f"q{i}", "question": "Q?", "correct_answer": "ok", "type": "text"}
                for i in range(5)]
        p = _write_batch(tmp_path, "data.json", big)

        monkeypatch.setattr(dor, "collect_files", lambda include_exports=False: [p])
        monkeypatch.setattr("sys.argv", ["delete_or_reject.py", "--out-dir", str(tmp_path)])

        rc = dor.main()
        assert rc == 2
        # No file mutation.
        assert _file_questions(p) == big
        # Log exists and records applied=False.
        log_path = tmp_path / f"cleanup-log-{__import__('datetime').date.today().isoformat()}.json"
        assert log_path.exists()
        log = json.loads(log_path.read_text())
        assert log["applied"] is False
        assert log["summary"]["rejected"] == 5

    def test_main_dry_run_no_mutation(self, tmp_path, monkeypatch):
        p = _write_batch(tmp_path, "data.json", [
            {"id": "q1", "question": "Procedural?", "correct_answer": PROCEDURAL_ANSWER, "type": "text"},
            {"id": "q2", "question": "Short?", "correct_answer": "Yes", "type": "text"},
        ])
        before = p.read_text()
        monkeypatch.setattr(dor, "collect_files", lambda include_exports=False: [p])
        # Cap=0.5 so the 1 procedural delete in this tiny 2-question fixture
        # fits under the cap (avoids fail-loud unrelated to dry-run semantics).
        monkeypatch.setattr("sys.argv",
                            ["delete_or_reject.py", "--dry-run", "--cap-frac", "0.5",
                             "--out-dir", str(tmp_path)])
        rc = dor.main()
        assert rc == 0
        assert p.read_text() == before


class TestModeFilters:
    def test_delete_only_skips_rejections(self, tmp_path):
        long_ans = "The text was printed on a physical surface and filmed with a camera"
        p = _write_batch(tmp_path, "b.json", [
            {"id": "q1", "question": "P?", "correct_answer": PROCEDURAL_ANSWER, "type": "text"},
            {"id": "q2", "question": "V?", "correct_answer": long_ans, "type": "text"},
        ])
        plans = [dor._plan_file(p)]
        for pl in plans:
            pl["rejects"] = []
        dor._apply_plan(plans[0])
        qs = _file_questions(p)
        # Procedural deleted, verbose untouched (no review_status added).
        assert len(qs) == 1
        assert qs[0]["id"] == "q2"
        assert "review_status" not in qs[0]
