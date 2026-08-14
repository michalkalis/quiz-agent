#!/usr/bin/env python3
"""One parser per historical founder-rating round (issue #156).

Pure functions: file paths in, `SourceResult` out — no DB, no I/O beyond
reading the source files, so every format quirk is testable from a fixture
snippet. `backfill_ratings.py` owns the writing.

Two rules run through all of them:

* **Fail loud.** A format the parser does not recognise raises `ParseError`
  rather than silently importing fewer rows. These files are hand-written
  markdown and hand-recovered JSON; a silently dropped row is a calibration
  data point nobody will ever notice is missing.
* **Stable natural keys.** The key is whatever the *source file* calls the
  question (orig id, sequential n, blinded qid, text hash) — never a value
  derived from a join that may succeed today and fail tomorrow. That is what
  makes a re-run an upsert instead of a duplicate.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

REPO_ROOT = Path(__file__).resolve().parents[3]

# Below this token-overlap the #153 baseline order-join is not trusted and the
# row is imported on its question-text snapshot instead (see `parse_baseline`).
BASELINE_MIN_SIMILARITY = 0.30

_STOPWORDS = {
    "what", "which", "does", "with", "that", "this", "from", "your", "when",
    "were", "been", "they", "their", "into", "only", "also", "most", "than",
    "have", "the", "and", "for", "true", "false",
}


class ParseError(RuntimeError):
    """A source file did not match the shape this parser was written for."""


@dataclass(frozen=True)
class ParsedRating:
    """One rating row, source-shaped, before it meets the database."""

    round: str
    natural_key: str
    question_text: str
    rater: str
    score: float
    scale_min: int
    scale_max: int
    rated_at: datetime
    reason: Optional[str] = None
    question_id: Optional[str] = None
    blinded_qid: Optional[str] = None
    extra: Optional[dict[str, Any]] = None

    @property
    def source(self) -> str:
        return f"backfill:{self.round}"

    @property
    def dedupe_key(self) -> str:
        return f"backfill:{self.round}:{self.natural_key}:{self.rater}"


@dataclass
class SourceResult:
    round: str
    rows: list[ParsedRating] = field(default_factory=list)
    seen: int = 0
    skipped: int = 0
    unjoinable: int = 0
    anomalies: list[str] = field(default_factory=list)


def _utc(day: str) -> datetime:
    return datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=timezone.utc)


def _text_key(text: str) -> str:
    """Short, stable hash of a question text — the key when nothing else is."""
    normalized = " ".join(text.lower().split())
    return hashlib.sha1(normalized.encode("utf-8")).hexdigest()[:16]


def _content_tokens(text: str) -> set[str]:
    words = re.sub(r"[^a-z0-9 ]", " ", text.lower()).split()
    return {w for w in words if len(w) >= 4 and w not in _STOPWORDS}


def similarity(shorthand: str, full: str) -> float:
    """Fraction of the shorthand's content words present in the full question.

    Not a prefix match: the founder's `q` field is a paraphrase ("Nokia
    originally made what (paper)"), so the check has to tolerate rewording
    while still catching a file that has drifted out of order.
    """
    a = _content_tokens(shorthand)
    if not a:
        return 0.0
    return len(a & _content_tokens(full)) / len(a)


# --------------------------------------------------------------------------
# Gold library — data/examples/gold_standard.json
# --------------------------------------------------------------------------

GOLD_ROUND = "gold-library"
GOLD_DATE = "2026-06-07"


def parse_gold_library(path: Path, rated_at: str = GOLD_DATE) -> SourceResult:
    """Human `human_rating` rows only; `rated_by == "auto"` is not a rating.

    The auto rows are the model's own self-assessment used to seed the library
    — importing them would pollute exactly the human/model correlation this
    store exists to measure.
    """
    result = SourceResult(round=GOLD_ROUND)
    entries = json.loads(path.read_text())
    if not isinstance(entries, list):
        raise ParseError(f"{path}: expected a JSON list of gold entries")
    when = _utc(rated_at)
    seen_keys: set[str] = set()
    for i, entry in enumerate(entries):
        result.seen += 1
        rater = entry.get("rated_by")
        if not rater:
            raise ParseError(f"{path}#{i}: entry has no `rated_by`")
        if rater == "auto":
            result.skipped += 1
            continue
        question = (entry.get("question") or "").strip()
        score = entry.get("human_rating")
        if not question or score is None:
            raise ParseError(f"{path}#{i}: human row missing question/human_rating")
        key = _text_key(question)
        if key in seen_keys:
            raise ParseError(f"{path}#{i}: duplicate question text — key collision")
        seen_keys.add(key)
        result.rows.append(
            ParsedRating(
                round=GOLD_ROUND,
                natural_key=key,
                question_text=question,
                rater=rater,
                score=float(score),
                scale_min=1,
                scale_max=10,
                rated_at=when,
                reason=entry.get("why_excellent"),
                extra={
                    "topic": entry.get("topic"),
                    "pattern": entry.get("pattern"),
                    "generator": entry.get("generator"),
                    "difficulty": entry.get("difficulty"),
                    "decision": entry.get("decision"),
                    "answer": entry.get("answer"),
                },
            )
        )
    if result.skipped:
        result.anomalies.append(
            f"{result.skipped} entries excluded as rated_by='auto' (model self-rating)"
        )
    return result


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
    dates = {"round-1": _utc(PILOT_DATE), "round-2": _utc(r2.group(1))}

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
    when = _utc(rated_at)

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


# --------------------------------------------------------------------------
# #153 baseline / Bedrock batch 2026-08-07
# --------------------------------------------------------------------------

BASELINE_ROUND = "153-baseline-2026-08-07"
BASELINE_DATE = "2026-08-07"


def parse_baseline(
    ratings_json: Path, questions_json: Path, rated_at: str = BASELINE_DATE
) -> SourceResult:
    """Sequential `n` → question UUID by order, sanity-checked against the text.

    The founder's `q` is shorthand, not a quote, so the join is positional and
    the text only *verifies* it. A row whose shorthand shares too little with
    the question at that position is imported without a UUID — on its own text
    — and reported, rather than being attached to a question it may not be.
    """
    result = SourceResult(round=BASELINE_ROUND)
    payload = json.loads(ratings_json.read_text())
    questions = json.loads(questions_json.read_text())
    if not isinstance(questions, list):
        raise ParseError(f"{questions_json}: expected a JSON list of questions")
    when = _utc(rated_at)
    batch = payload.get("batch")
    seen_n: set[int] = set()

    for entry in payload.get("ratings", []):
        result.seen += 1
        n = entry.get("n")
        if not isinstance(n, int) or n < 1:
            raise ParseError(f"{ratings_json}: rating without a positive `n`: {entry}")
        if n in seen_n:
            raise ParseError(f"{ratings_json}: n={n} appears twice")
        seen_n.add(n)
        shorthand = (entry.get("q") or "").strip()
        if entry.get("score") is None:
            result.skipped += 1
            continue
        if n > len(questions):
            raise ParseError(
                f"{ratings_json}: n={n} beyond {len(questions)} questions — order join broken"
            )
        target = questions[n - 1]
        sim = round(similarity(shorthand, target.get("question", "")), 3)
        joined = sim >= BASELINE_MIN_SIMILARITY
        if not joined:
            result.unjoinable += 1
            result.anomalies.append(
                f"n={n} unjoinable (similarity {sim}): '{shorthand}' vs "
                f"'{target.get('question', '')[:60]}…'"
            )
        result.rows.append(
            ParsedRating(
                round=BASELINE_ROUND,
                natural_key=f"n{n:02d}",
                question_text=target["question"] if joined else shorthand,
                rater="michal",
                score=float(entry["score"]),
                scale_min=1,
                scale_max=10,
                rated_at=when,
                reason=entry.get("reason") or entry.get("note") or None,
                question_id=str(target["id"]) if joined else None,
                extra={
                    "n": n,
                    "batch": batch,
                    "topic": entry.get("topic"),
                    "type": entry.get("type"),
                    "difficulty": entry.get("diff"),
                    "note": entry.get("note"),
                    "shorthand": shorthand,
                    "text_similarity": sim,
                    "joined": joined,
                },
            )
        )
    if result.skipped:
        result.anomalies.append(f"{result.skipped} rows had score=null (not rated)")
    return result


# --------------------------------------------------------------------------
# #153 Phase A round 1
# --------------------------------------------------------------------------

PHASE_A_ROUND = "153-phase-a-r1"
PHASE_A_DATE = "2026-08-07"


def parse_phase_a(
    ratings_json: Path, mapping_json: Path, rated_at: str = PHASE_A_DATE
) -> SourceResult:
    """Blinded `qNN` → arm + original UUID via `mapping.json`.

    The arm is asserted, not trusted: the ratings file carries a de-blinded
    `arm` recovered from a PDF, and if it disagrees with the server-side
    mapping then one of the two is wrong and every per-arm number computed
    from this round would be wrong with it.
    """
    result = SourceResult(round=PHASE_A_ROUND)
    payload = json.loads(ratings_json.read_text())
    mapping = json.loads(mapping_json.read_text())
    when = _utc(rated_at)
    batch_id = payload.get("batch_id")

    for entry in payload.get("ratings", []):
        result.seen += 1
        qid = entry.get("id")
        if not qid:
            raise ParseError(f"{ratings_json}: rating without an `id`: {entry}")
        target = mapping.get(qid)
        if target is None:
            raise ParseError(f"{mapping_json}: no mapping entry for {qid}")
        if entry.get("arm") and entry["arm"] != target.get("arm"):
            raise ParseError(
                f"{qid}: arm '{entry['arm']}' contradicts mapping '{target.get('arm')}'"
            )
        if entry.get("score") is None:
            result.skipped += 1
            continue
        question = (target.get("question") or entry.get("question") or "").strip()
        if not question:
            raise ParseError(f"{qid}: no question text in mapping or ratings")
        result.rows.append(
            ParsedRating(
                round=PHASE_A_ROUND,
                natural_key=qid,
                question_text=question,
                rater="michal",
                score=float(entry["score"]),
                scale_min=1,
                scale_max=10,
                rated_at=when,
                reason=entry.get("reason") or None,
                question_id=str(target["original_id"]) if target.get("original_id") else None,
                blinded_qid=qid,
                extra={
                    "arm": target.get("arm"),
                    "topic": target.get("topic") or entry.get("topic"),
                    "batch_id": batch_id,
                    "blinded_qid": qid,
                },
            )
        )
    if result.skipped:
        result.anomalies.append(f"{result.skipped} rows had score=null (not rated)")
    return result
