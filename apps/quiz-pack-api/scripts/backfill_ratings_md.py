#!/usr/bin/env python3
"""The two founder-rating rounds that live in hand-written markdown (#156).

Split from `backfill_ratings_parsers` (which keeps the shared row model and
the JSON-shaped rounds) because these two are a different kind of problem:
prose written for a human reader, where the score, the model key and the
question text sit in three different places in the document and the only
thing holding them together is a regex. They earn their own file — and their
own dense test coverage — for that reason.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from scripts.backfill_ratings_parsers import (
    ParsedRating,
    ParseError,
    SourceResult,
    utc_date,
)

# --------------------------------------------------------------------------
# Pilot 2026-07-11 — apps/quiz-pack-api/data/pilot-2026-07-11/
# --------------------------------------------------------------------------

PILOT_ROUND = "pilot-2026-07-11"
PILOT_DATE = "2026-07-11"
_PILOT_KEY = re.compile(r"\b([ABC]) = ([^·\n]+)")
_PILOT_R2_DATE = re.compile(r"^##\s*Round 2\s*\((\d{4}-\d{2}-\d{2})\)", re.M)
_PILOT_ROW = re.compile(r"^\|\s*((?:R2-)?Q\d+)\s*\|\s*([ABC]\d+)\s*\|\s*([ABC])\s*\|"
                        r"\s*([0-9]+(?:\.[0-9])?)\s*\|\s*(.*?)\s*\|\s*$", re.M)
_PILOT_REVIEW_Q = re.compile(r"^\*\*([ABC]\d+)\.\s*\[([^\]]+)\]\*\*\s*(.+)$", re.M)


def parse_pilot(ratings_md: Path, review_md: Path) -> SourceResult:
    """`founder_ratings.md` tables joined to the question texts in `pilot_review.md`.

    The ratings file carries only the blind `Orig ID` (A12/B10/…), so the text
    snapshot — the whole point of the store surviving its source — has to come
    from the review file. A missing id is a hard error: it means the two files
    have drifted apart and the row would be stored against the wrong question.
    """
    result = SourceResult(round=PILOT_ROUND)
    text = ratings_md.read_text()
    key_map = dict(
        (letter, model.strip()) for letter, model in _PILOT_KEY.findall(text)
    )
    if set(key_map) != {"A", "B", "C"}:
        raise ParseError(f"{ratings_md}: model key A/B/C not found in header")

    r2 = _PILOT_R2_DATE.search(text)
    if not r2:
        raise ParseError(f"{ratings_md}: no '## Round 2 (YYYY-MM-DD)' heading")
    dates = {"round-1": utc_date(PILOT_DATE), "round-2": utc_date(r2.group(1))}

    questions = {
        qid: (qtype, qtext.strip())
        for qid, qtype, qtext in _PILOT_REVIEW_Q.findall(review_md.read_text())
    }
    if not questions:
        raise ParseError(f"{review_md}: no '**A1. [type]** question' blocks found")

    seen_ids: set[str] = set()
    for label, orig_id, letter, score, notes in _PILOT_ROW.findall(text):
        result.seen += 1
        if not orig_id.startswith(letter):
            raise ParseError(
                f"{ratings_md}: row {label} claims model {letter} but id is {orig_id}"
            )
        if orig_id in seen_ids:
            raise ParseError(f"{ratings_md}: orig id {orig_id} rated twice")
        seen_ids.add(orig_id)
        if orig_id not in questions:
            raise ParseError(f"{review_md}: no question text for orig id {orig_id}")
        rnd = "round-2" if label.startswith("R2-") else "round-1"
        qtype, qtext = questions[orig_id]
        result.rows.append(
            ParsedRating(
                round=PILOT_ROUND,
                natural_key=orig_id,
                question_text=qtext,
                rater="michal",
                score=float(score),
                scale_min=1,
                scale_max=5,
                rated_at=dates[rnd],
                reason=notes or None,
                extra={
                    "orig_id": orig_id,
                    "label": label,
                    "pilot_round": rnd,
                    "model_letter": letter,
                    "model": key_map[letter],
                    "question_type": qtype,
                },
            )
        )
    return result


# --------------------------------------------------------------------------
# G3 corpus blind sample — docs/testing/runs/corpus-blind-sample-2026-07.md
# --------------------------------------------------------------------------

G3_ROUND = "g3-corpus-blind-2026-07"
G3_DATE = "2026-07-15"
_G3_Q = re.compile(r"^\*\*(\d+)\.\s*\[([^\]]+)\]\s*([^*]*?)\*\*\s*—\s*(.+)$", re.M)
_G3_SCORE = re.compile(r"^\s*-\s*\*\*Founder skóre:\s*(.+?)\*\*\s*(.*)$", re.M)
_G3_FRACTION = re.compile(r"(~?)\s*(\d+(?:[.,]\d+)?)\s*/\s*5")
_G3_KEY_ROW = re.compile(r"^\|\s*(\d+)\s*\|\s*([^|]+?)\s*\|\s*(.+?)\s*\|\s*$", re.M)


def parse_g3_sample(path: Path, rated_at: str = G3_DATE) -> SourceResult:
    """Inline `Founder skóre: X/5` lines, de-blinded by the answer-key table.

    Two founder-written shapes the regex has to survive: an approximate score
    (`~4/5`) and a split one (`kreativita 5/5, formát 3/5`). The split is
    imported as the mean with both components kept in `extra` and reported as
    an anomaly — dropping the row would lose a rated question, and picking one
    half silently would invent a founder verdict that was never given.
    """
    result = SourceResult(round=G3_ROUND)
    text = path.read_text()
    blocks = _G3_Q.findall(text)
    if len(blocks) != 10:
        raise ParseError(f"{path}: expected 10 question blocks, found {len(blocks)}")

    key: dict[str, tuple[str, str]] = {}
    for num, model, src in _G3_KEY_ROW.findall(text):
        if model in ("Model", "-------") or set(model) <= {"-", " "}:
            continue
        key.setdefault(num, (model, src))
    when = utc_date(rated_at)

    # Score lines are matched positionally against the question blocks: the Nth
    # `Founder skóre` line belongs to the Nth question.
    score_lines = _G3_SCORE.findall(text)
    if len(score_lines) != len(blocks):
        raise ParseError(
            f"{path}: {len(blocks)} questions but {len(score_lines)} score lines"
        )

    for (num, qtype, category, question), (raw, tail) in zip(blocks, score_lines):
        result.seen += 1
        if num not in key:
            raise ParseError(f"{path}: question {num} missing from the answer key")
        fractions = _G3_FRACTION.findall(raw)
        if not fractions:
            raise ParseError(f"{path}: question {num} score '{raw}' has no X/5 value")
        values = [float(v.replace(",", ".")) for _, v in fractions]
        score = sum(values) / len(values)
        extra: dict[str, Any] = {
            "question_number": num,
            "question_type": qtype,
            "category": category,
            "model": key[num][0],
            "source_ref": key[num][1],
            "raw_score_text": raw,
        }
        if any(approx for approx, _ in fractions):
            extra["approximate"] = True
            result.anomalies.append(f"q{num}: approximate score '{raw}'")
        if len(values) > 1:
            extra["score_components"] = values
            result.anomalies.append(
                f"q{num}: split score '{raw}' imported as mean {score}"
            )
        result.rows.append(
            ParsedRating(
                round=G3_ROUND,
                natural_key=f"q{int(num):02d}",
                question_text=question.strip(),
                rater="michal",
                score=score,
                scale_min=1,
                scale_max=5,
                rated_at=when,
                reason=tail.lstrip("— ").strip() or None,
                extra=extra,
            )
        )
    return result


