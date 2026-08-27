"""Post-cutoff acceptance filter for the #167 entertainment pilot (D6).

**Fully offline** — this script never makes a network call. It reads a batch
dumped by ``generate_pack.py --out`` (a plain JSON array of full
``Question.model_dump`` dicts, see ``generate_pack.py:355-372``) and splits it
into ``<stem>_accepted.json`` / ``<stem>_rejected.json``.

Why it exists (D1): the class this pilot generates is *post-cutoff settled
facts*, not news. Such a fact classifies as ``evergreen`` → ``freshness_tag =
NULL`` — byte-identical to a real evergreen row and to a classifier fail-safe.
``freshness_tag`` therefore **provably cannot** gate this class, so this filter
is the ONLY gate that measures the defining property of the question class.

Predicate (D6) — a row is accepted iff **both** hold:

1. a year token ≥ 2026 appears in ``question``, in the answer, **or** in the
   excerpt of the fact the row came from;
2. ``freshness_tag != "current"``.

The excerpt leg is **best-effort**: rows carry ``source_excerpt`` only when
``_attribute_sources`` filled it in (the model emitted no URL of its own), so
for every other row the excerpt is joined offline out of the ``--facts-file``
by normalized ``source_url``. A row whose model-emitted URL is absent from the
fact file simply falls back to its question/answer text — an accepted
degradation, not a bug.

Every rejected row carries a ``reason``: ``no_2026_token`` /
``freshness_current``.

    uv run --no-sync python scripts/filter_postcutoff.py pilot_167.json \
        --facts-file facts_167.json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.orchestrator.stages.dedup import _normalize_url
from quiz_shared.models.question import Question

# "Post-cutoff" is year 2026 (founder decision 5 — Fable 5's cutoff is Jan
# 2026). Only 19xx/20xx literals count as year tokens: a bare ``\d{4}`` would
# read "sold 3000 copies" as a year and wave the row through.
POST_CUTOFF_YEAR = 2026
_YEAR_RE = re.compile(r"\b(?:19|20)\d{2}\b")

REASON_NO_YEAR = "no_2026_token"
REASON_FRESHNESS_CURRENT = "freshness_current"


# ---------------------------------------------------------------------------
# Predicate (167.6)
# ---------------------------------------------------------------------------


def _has_post_cutoff_year(text: str) -> bool:
    return any(int(m) >= POST_CUTOFF_YEAR for m in _YEAR_RE.findall(text))


def _answer_text(question: Question) -> str:
    """The answer surface a year token may live in.

    MCQ rows store ``correct_answer`` either as the option text or as the bare
    option key ("b"); a lone letter carries no year, so a key is resolved to
    the option text the player would actually see.
    """
    raw = question.correct_answer
    values = raw if isinstance(raw, list) else [raw]
    options = question.possible_answers or {}
    parts: list[str] = []
    for value in values:
        text = str(value)
        parts.append(text)
        if text in options:
            parts.append(options[text])
    return " ".join(parts)


def _load_fact_excerpts(path: str | Path) -> dict[str, str]:
    """Normalized ``source_url`` → excerpt text, from a ``source_facts.py`` file.

    The file format is the one ``_FactsFileSourcingStage`` reads
    (``generate_pack.py:241-252``): ``{"topics": [...], "facts": [...]}``.
    Several facts can share one URL (a listicle) and the row does not record
    WHICH of them it came from, so all excerpts of a URL are joined — the
    best-effort leg is deliberately recall-favouring: a false accept is caught
    by the founder's rating, a false negative silently shrinks the batch.
    """
    with open(path, "r", encoding="utf-8") as fh:
        payload = json.load(fh)
    excerpts: dict[str, list[str]] = {}
    for fact in payload.get("facts", []):
        url = fact.get("source_url")
        text = fact.get("excerpt") or fact.get("text")
        if not url or not text:
            continue
        excerpts.setdefault(_normalize_url(url), []).append(str(text))
    return {url: " ".join(parts) for url, parts in excerpts.items()}


def _excerpt_for(question: Question, excerpts: dict[str, str]) -> str | None:
    if question.source_excerpt:
        return question.source_excerpt
    if not question.source_url:
        return None
    return excerpts.get(_normalize_url(question.source_url))


def _rejection_reason(question: Question, excerpt: str | None) -> str | None:
    """``None`` when the row is accepted, else the D6 reason it was dropped."""
    haystack = " ".join(
        part for part in (question.question, _answer_text(question), excerpt) if part
    )
    if not _has_post_cutoff_year(haystack):
        return REASON_NO_YEAR
    if (question.freshness_tag or "").strip().lower() == "current":
        return REASON_FRESHNESS_CURRENT
    return None


# ---------------------------------------------------------------------------
# I/O + CLI
# ---------------------------------------------------------------------------


def _load_batch(path: str | Path) -> list[dict[str, Any]]:
    with open(path, "r", encoding="utf-8") as fh:
        payload = json.load(fh)
    if not isinstance(payload, list):
        raise SystemExit(
            f"{path}: expected a plain JSON array of questions "
            "(the shape generate_pack.py --out writes)."
        )
    return payload


def _write_json(path: Path, rows: list[dict[str, Any]]) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(rows, fh, ensure_ascii=False, indent=2)
        fh.write("\n")


def filter_batch(
    rows: list[dict[str, Any]],
    excerpts: dict[str, str],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Split ``rows`` into (accepted, rejected-with-reason)."""
    accepted: list[dict[str, Any]] = []
    rejected: list[dict[str, Any]] = []
    for row in rows:
        question = Question.model_validate(row)
        reason = _rejection_reason(question, _excerpt_for(question, excerpts))
        if reason is None:
            accepted.append(row)
        else:
            rejected.append({**row, "reason": reason})
    return accepted, rejected


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        description=(
            "Offline post-cutoff acceptance filter for #167 (D6). Splits a "
            "generate_pack.py --out batch into <stem>_accepted.json / "
            "<stem>_rejected.json."
        )
    )
    ap.add_argument(
        "batch", help="Batch JSON written by generate_pack.py --out (JSON array)."
    )
    ap.add_argument(
        "--facts-file",
        default=None,
        help=(
            "Fact file from source_facts.py; supplies the offline excerpt join "
            "for rows without source_excerpt. Omitting it weakens the accept "
            "leg to question/answer text only."
        ),
    )
    return ap.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)

    rows = _load_batch(args.batch)
    excerpts = _load_fact_excerpts(args.facts_file) if args.facts_file else {}

    accepted, rejected = filter_batch(rows, excerpts)

    batch_path = Path(args.batch)
    accepted_path = batch_path.parent / f"{batch_path.stem}_accepted.json"
    rejected_path = batch_path.parent / f"{batch_path.stem}_rejected.json"
    _write_json(accepted_path, accepted)
    _write_json(rejected_path, rejected)

    counts: dict[str, int] = {}
    for row in rejected:
        counts[row["reason"]] = counts.get(row["reason"], 0) + 1

    print(f"post-cutoff filter — {args.batch}")
    print(f"  input rows:        {len(rows)}")
    print(f"  accepted:          {len(accepted)}")
    print(f"  rejected:          {len(rejected)}")
    for reason in (REASON_NO_YEAR, REASON_FRESHNESS_CURRENT):
        if reason in counts:
            print(f"    {reason}: {counts[reason]}")
    if not args.facts_file:
        print("  WARNING: no --facts-file — excerpt leg of the predicate is off.")
    print(f"  wrote {accepted_path}")
    print(f"  wrote {rejected_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
