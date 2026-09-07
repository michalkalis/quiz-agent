"""Re-score a persisted DD13 answerability pre-check (#168 — batch translation
pipeline SK/CS, T10) with the CURRENT comparator — no model calls.

The pre-check stores both legs per item precisely so a comparator re-tune can
be measured without re-running the model (and without OpenRouter spend). This
reads the run file plus the arm file it was scored against, re-applies
``_resolve_option_key`` / ``_text_answer_matches`` to the stored target answer,
and reports the flip rate. Only a leg that failed on the COMPARATOR
(``wrong_answer``, or a pass) is re-scored: ``unanswerable``, ``flagged_*`` and
``check_unavailable`` are the model's own judgments, which no comparator change
can revisit. Original verdicts are never overwritten — the re-scored leg lands
under ``results[i].rescored``.

    python scripts/answerability_precheck_rescore.py [--write]
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.translation_verification.answerability import (  # noqa: E402
    _resolve_option_key,
    _text_answer_matches,
)
from app.translation_verification.draft import TranslatedDraft  # noqa: E402
from app.translation_verification.normalize import fold  # noqa: E402

_RUNS = Path(__file__).resolve().parents[3] / "docs/testing/runs/168-translation-arms"
_COMPARATOR_REASONS = (None, "wrong_answer")


def _correct_answer_key(payload: dict) -> str | None:
    """The option key the arm file's ``correct_answer`` denotes (DD3 shape)."""
    options = payload.get("possible_answers") or {}
    correct = str(payload.get("correct_answer") or "")
    by_key = {str(k).strip().lower(): str(v) for k, v in options.items()}
    if fold(correct) in by_key:
        return fold(correct)
    for key, value in by_key.items():
        if fold(correct) == fold(value):
            return key
    return None


def _rescore(leg: dict, draft: TranslatedDraft) -> bool:
    """The current comparator's verdict on the stored target answer."""
    answer = str(leg.get("answer") or "")
    if draft.possible_answers:
        picked = _resolve_option_key(answer, draft.possible_answers)
        return picked is not None and picked == str(draft.correct_answer_key or "")
    references = [draft.correct_answer, *(draft.alternative_answers or [])]
    return _text_answer_matches(answer, [str(r) for r in references])


def _verdict(en_passed: bool, target_passed: bool, unavailable: bool) -> str:
    if unavailable:
        return "unavailable"
    if en_passed and not target_passed:
        return "translation_flip"
    if not en_passed:
        return "control_fail"
    return "pass"


def _report(label: str, verdicts: list[str]) -> None:
    counts = Counter(verdicts)
    total = len(verdicts)
    flips = counts["translation_flip"]
    rate = (flips / total * 100) if total else 0.0
    print(f"{label}: n={total} flips={flips} ({rate:.1f} %) {dict(counts)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--precheck", type=Path, default=_RUNS / "answerability-precheck-sk.json"
    )
    parser.add_argument("--arm", type=Path, default=_RUNS / "gemini-sk.json")
    parser.add_argument(
        "--write", action="store_true", help="persist results[i].rescored"
    )
    args = parser.parse_args()

    run = json.loads(args.precheck.read_text())
    arm = {item["id"]: item for item in json.loads(args.arm.read_text())}

    for result in run["results"]:
        payload = arm[result["id"]]
        draft = TranslatedDraft.from_payload(
            {**payload, "correct_answer_key": _correct_answer_key(payload)}
        )
        target, en = result["target"], result["en"]
        if target.get("reason") in _COMPARATOR_REASONS:
            passed = _rescore(target, draft)
            reason = None if passed else "wrong_answer"
        else:
            passed, reason = bool(target.get("passed")), target.get("reason")
        result["rescored"] = {
            "target": {
                "answer": target.get("answer"),
                "passed": passed,
                "reason": reason,
            },
            "verdict": _verdict(
                bool(en.get("passed")),
                passed,
                en.get("reason") == "check_unavailable"
                or reason == "check_unavailable",
            ),
        }

    approved = [r for r in run["results"] if r.get("approved")]
    other = [r for r in run["results"] if not r.get("approved")]
    for label, rows in (
        ("approved", approved),
        ("not-approved", other),
        ("all", run["results"]),
    ):
        _report(f"{label} ORIGINAL ", [r["verdict"] for r in rows])
        _report(f"{label} RESCORED ", [r["rescored"]["verdict"] for r in rows])
    for r in run["results"]:
        if r["verdict"] != r["rescored"]["verdict"]:
            print(
                f"  changed {r['id']} approved={r['approved']} mcq={r['mcq']}: "
                f"{r['verdict']} -> {r['rescored']['verdict']} "
                f"(target answer: {r['target']['answer']!r})"
            )
    if args.write:
        # indent=1 is the run file's own formatting — keep the diff to the
        # added ``rescored`` keys so the original verdicts stay reviewable.
        args.precheck.write_text(json.dumps(run, ensure_ascii=False, indent=1))
        print(f"wrote {args.precheck}")


if __name__ == "__main__":
    main()
