"""Delete procedural questions and mark unfixable verbose ones as rejected.

Issue #42 task 42.3.

Pipeline (per question, in this order):
  1. Apply ``auto_fix_answers.fix_question_inplace`` so the em-dash / "because"
     tail is split off before we judge verbosity.
  2. If classified as ``procedural``: schedule for **deletion** from the file.
  3. Else if ``correct_answer`` still exceeds ``VERBOSE_LIMIT`` words: schedule
     a ``review_status="rejected"`` annotation with a ``rejection_reason``.

Two-phase write to keep the safety cap meaningful:
  - Phase 1 computes all changes without mutating anything on disk.
  - Phase 2 either applies every change atomically + writes the audit log, or
    aborts loudly (no mutation) when ``deleted + rejected`` exceeds ``--cap``
    (default 5% of corpus). Idempotent: a second run with no candidates is a
    no-op.

Audit log: ``docs/artifacts/cleanup-log-<date>.json``.
"""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from copy import deepcopy
from datetime import date
from pathlib import Path
from typing import Any

from scripts.answer_quality_audit import _classify, _word_count
from scripts.auto_fix_answers import fix_question_inplace

REPO_ROOT = Path(__file__).resolve().parents[3]
GENERATED_DIR = REPO_ROOT / "data" / "generated"
PROD_EXPORTS = [
    REPO_ROOT / "apps" / "quiz-agent" / "questions_export.json",
    REPO_ROOT / "questions_export.json",
]
ARTIFACTS_DIR = REPO_ROOT / "docs" / "artifacts"

VERBOSE_LIMIT = 10
DEFAULT_CAP_FRAC = 0.05
REJECTION_REASON = "correct_answer_too_long_after_autofix"


def _question_ref(file_rel: str, index: int, q: dict[str, Any]) -> dict[str, Any]:
    """Stable identifier for the audit log — prefers ``id`` but falls back to
    ``(file, index)`` since legacy data/generated batches store ``id=None``."""
    return {
        "id": q.get("id"),
        "file": file_rel,
        "index": index,
        "question": (q.get("question") or "")[:160],
    }


def _plan_file(path: Path) -> dict[str, Any]:
    """Return a plan for one file: which indices to delete vs reject, plus the
    post-autofix copy of the data ready to write.

    No mutation of ``path`` itself; the loaded dict is deep-copied first.
    """
    raw = json.loads(path.read_text())
    data = deepcopy(raw)
    if isinstance(data, dict) and isinstance(data.get("questions"), list):
        questions = data["questions"]
        container = data
        is_dict_wrapped = True
    elif isinstance(data, list):
        questions = data
        container = data
        is_dict_wrapped = False
    else:
        return {"path": path, "deletes": [], "rejects": [], "data": raw, "dirty": False}

    file_rel = _safe_relpath(path)
    deletes: list[dict[str, Any]] = []
    rejects: list[dict[str, Any]] = []
    autofix_count = 0

    for idx, q in enumerate(questions):
        if not isinstance(q, dict):
            continue
        if fix_question_inplace(q) is not None:
            autofix_count += 1
        cats = _classify(q)
        if "procedural" in cats:
            deletes.append(_question_ref(file_rel, idx, q))
            continue
        ans = (q.get("correct_answer") or "").strip()
        if _word_count(ans) > VERBOSE_LIMIT:
            entry = _question_ref(file_rel, idx, q)
            entry["correct_answer"] = ans
            entry["word_count"] = _word_count(ans)
            rejects.append(entry)

    return {
        "path": path,
        "file_rel": file_rel,
        "deletes": deletes,
        "rejects": rejects,
        "autofix_count": autofix_count,
        "data": container,
        "is_dict_wrapped": is_dict_wrapped,
        "dirty": True,
    }


def _safe_relpath(path: Path) -> str:
    try:
        return str(path.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def _apply_plan(plan: dict[str, Any]) -> None:
    """Mutate the in-memory ``data`` per the plan and write it back to disk."""
    if not plan.get("dirty"):
        return
    data = plan["data"]
    if isinstance(data, dict) and isinstance(data.get("questions"), list):
        questions = data["questions"]
    elif isinstance(data, list):
        questions = data
    else:
        return

    delete_indices = {d["index"] for d in plan["deletes"]}
    reject_indices = {r["index"] for r in plan["rejects"]}

    # Apply rejection annotations first (index-stable), then delete in reverse.
    for idx in reject_indices:
        q = questions[idx]
        q["review_status"] = "rejected"
        q["rejection_reason"] = REJECTION_REASON

    for idx in sorted(delete_indices, reverse=True):
        questions.pop(idx)

    plan["path"].write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def collect_files(include_exports: bool = False) -> list[Path]:
    files = sorted(GENERATED_DIR.glob("*.json"))
    if include_exports:
        for p in PROD_EXPORTS:
            if p.exists():
                files.append(p)
    return files


def plan_all(paths: list[Path]) -> list[dict[str, Any]]:
    return [_plan_file(p) for p in paths]


def cap_check(plans: list[dict[str, Any]], total_questions: int, cap_frac: float) -> tuple[int, int, int]:
    n_del = sum(len(p["deletes"]) for p in plans)
    n_rej = sum(len(p["rejects"]) for p in plans)
    cap = int(total_questions * cap_frac)
    return n_del, n_rej, cap


def _count_questions(paths: list[Path]) -> int:
    total = 0
    for p in paths:
        try:
            data = json.loads(p.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        qs = data["questions"] if isinstance(data, dict) and "questions" in data else data
        if isinstance(qs, list):
            total += len(qs)
    return total


def _write_log(plans: list[dict[str, Any]], total_questions: int, cap: int, applied: bool, out_dir: Path) -> Path:
    log = {
        "generated_on": date.today().isoformat(),
        "applied": applied,
        "rejection_reason": REJECTION_REASON,
        "verbose_limit": VERBOSE_LIMIT,
        "cap": cap,
        "total_questions": total_questions,
        "summary": {
            "deleted": sum(len(p["deletes"]) for p in plans),
            "rejected": sum(len(p["rejects"]) for p in plans),
            "autofixed": sum(p.get("autofix_count", 0) for p in plans),
        },
        "deletes": [d for p in plans for d in p["deletes"]],
        "rejects": [r for p in plans for r in p["rejects"]],
    }
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"cleanup-log-{log['generated_on']}.json"
    out_path.write_text(json.dumps(log, indent=2, ensure_ascii=False))
    return out_path


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dry-run", action="store_true", help="Plan only; no writes.")
    ap.add_argument("--include-exports", action="store_true",
                    help="Also process apps/quiz-agent/questions_export.json + root copy (used by 42.4).")
    ap.add_argument("--cap-frac", type=float, default=DEFAULT_CAP_FRAC,
                    help=f"Abort if deleted+rejected exceeds this fraction of corpus (default {DEFAULT_CAP_FRAC}).")
    ap.add_argument("--mode", choices=["all", "delete-only", "reject-only"], default="all",
                    help="Limit which mutations to apply.")
    ap.add_argument("--out-dir", type=Path, default=ARTIFACTS_DIR)
    args = ap.parse_args()

    files = collect_files(include_exports=args.include_exports)
    total_q = _count_questions(files)
    plans = plan_all(files)

    if args.mode == "delete-only":
        for p in plans:
            p["rejects"] = []
    elif args.mode == "reject-only":
        for p in plans:
            p["deletes"] = []

    n_del, n_rej, cap = cap_check(plans, total_q, args.cap_frac)
    print(f"corpus={total_q} cap={cap} deletes={n_del} rejects={n_rej}")

    if n_del + n_rej > cap:
        log_path = _write_log(plans, total_q, cap, applied=False, out_dir=args.out_dir)
        print(f"FAIL-LOUD: deletes+rejects ({n_del + n_rej}) exceeds cap ({cap}). No files mutated.")
        print(f"  Candidate log: {_safe_relpath(log_path)}")
        return 2

    if args.dry_run:
        log_path = _write_log(plans, total_q, cap, applied=False, out_dir=args.out_dir)
        print(f"dry-run; log at {_safe_relpath(log_path)}")
        return 0

    for plan in plans:
        if plan["deletes"] or plan["rejects"]:
            _apply_plan(plan)

    log_path = _write_log(plans, total_q, cap, applied=True, out_dir=args.out_dir)
    print(f"applied. log: {_safe_relpath(log_path)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
