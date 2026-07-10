"""Deterministic craft guards — #72 reviewer upgrade (founder calibration 2026-07-09/10).

These catch the craft defects the founder flagged as *independent of fact
quality* ("great facts, broken craft"): the answer leaking from the stem and
telegraphed true/false batches. Both are explicit constraints, so they live in
code, not in an LLM judgment (backend rule: model only for judgment calls).

Calibration source: `docs/research/question-quality-founder-calibration-2026-07-09.md`
(Napoleon Q29 — stem says "British wartime propaganda", answer "Britain";
T/F corpus bias — 32 of 34 keys are "True").

Both guards are conservative by design and run in SHADOW by default (flag +
count, drop nothing); `CRAFT_GUARDS_ENFORCE` promotes them to dropping. They
are a lexical first layer only — morphological edge cases (France/French) are
owned by the LLM reviewer red flags, per the layered-detection design in
`docs/research/question-craft-prior-art-2026-07-10.md`.
"""

from __future__ import annotations

import math
import re
from collections import Counter

_TOKEN_RE = re.compile(r"[a-z0-9]+")

# Generic quiz-prose words that co-occur with answers without leaking them
# ("How many TIMES does the heart beat..." → answer "100,000 times" is a
# founder 5/5, not a leak), plus categorical nouns that classify an answer
# without identifying it ("the river flowing beneath the Amazon RIVER" does
# not leak "Hamza RIVER"). Extends a minimal English stopword core.
_STOPWORDS = frozenset(
    """a an and are as at be by for from has have how in is it its of on or
    that the this to was were what when where which who whose why with you
    your can does did do most more many much only also both each very
    name named called known times time year years world word term kind type
    part first last new old
    river mountain lake sea ocean city island country state animal insect
    bird fish plant
    """.split()
)

# Answer tokens shorter than this can only leak via an exact match; longer
# ones also match on a shared 4-char prefix (catches British↔Britain,
# dragonfly↔dragonflies) without firing on short accidental overlaps.
_PREFIX_MIN_LEN = 6
_PREFIX_LEN = 4

# T/F balance: only judge batches with enough T/F items to have a
# distribution, and allow the majority key up to 60% before flagging the
# excess (a strict 50/50 would flag every odd-sized batch).
_TF_MIN_COUNT = 4
_TF_MAJORITY_ALLOWED = 0.6


def _content_tokens(text: str) -> set[str]:
    return {
        t
        for t in _TOKEN_RE.findall(text.lower())
        if len(t) >= 3 and t not in _STOPWORDS
    }


def stem_leak_reason(
    question: str,
    correct_answer: object,
    possible_answers: dict | None = None,
) -> str | None:
    """Reason string when the stem gives the answer away lexically, else None.

    Flags when at least half of the answer's content words appear in the stem
    (exact token, or shared 4-char prefix for words of 6+ chars). MCQ is
    skipped: the key is a letter and option values legitimately appear
    alongside the stem — `distractor_quality` owns MCQ leak shapes. T/F is
    skipped too: every T/F stem may say "true or false", which is framing,
    not a leak — the T/F balance guard owns that format.
    """
    if possible_answers:
        return None
    if true_false_key(correct_answer) is not None:
        return None
    if isinstance(correct_answer, list):
        correct_answer = correct_answer[0] if correct_answer else ""
    answer_tokens = _content_tokens(str(correct_answer))
    if not answer_tokens:
        return None
    stem_tokens = _content_tokens(question)

    leaked: set[str] = set()
    for a in answer_tokens:
        if a in stem_tokens:
            leaked.add(a)
            continue
        if len(a) >= _PREFIX_MIN_LEN and any(
            len(s) >= _PREFIX_MIN_LEN and s[:_PREFIX_LEN] == a[:_PREFIX_LEN]
            for s in stem_tokens
        ):
            leaked.add(a)

    if len(leaked) / len(answer_tokens) >= 0.5:
        return f"stem_leak({','.join(sorted(leaked))})"
    return None


def true_false_key(
    correct_answer: object, possible_answers: dict | None = None
) -> str | None:
    """Normalized 'true'/'false' when the question is a T/F item, else None.

    Covers both shapes in the corpus: free-text with a True/False answer, and
    an MCQ whose two option values are exactly True and False (the key letter
    is resolved through the options).
    """
    if isinstance(correct_answer, list):
        correct_answer = correct_answer[0] if correct_answer else ""
    ans = str(correct_answer).strip().lower()

    if possible_answers:
        values = {str(v).strip().lower() for v in possible_answers.values()}
        if values != {"true", "false"}:
            return None
        resolved = {str(k).strip().lower(): str(v).strip().lower()
                    for k, v in possible_answers.items()}.get(ans)
        return resolved if resolved is not None else (ans if ans in values else None)

    return ans if ans in {"true", "false"} else None


def tf_imbalance_excess(items: list[tuple[str, str]]) -> list[str]:
    """Ids of majority-key T/F questions beyond the balanced allowance.

    ``items`` = (question_id, 'true'/'false') for every T/F item in the
    batch, in batch order. With fewer than ``_TF_MIN_COUNT`` items there is
    no distribution to judge → []. Otherwise the majority key may fill at
    most ceil(60%) of the T/F slots; later-in-batch excess items are the
    flag/drop candidates (deterministic, keeps the earliest ones).

    Why: 94% of the prod corpus's T/F keys are "True" — a player who always
    answers "True" nearly always wins. The founder called this from 2 samples.
    """
    if len(items) < _TF_MIN_COUNT:
        return []
    counts = Counter(key for _, key in items)
    majority_key, majority_n = counts.most_common(1)[0]
    if majority_n / len(items) <= _TF_MAJORITY_ALLOWED:
        return []
    allowed = math.ceil(_TF_MAJORITY_ALLOWED * len(items))
    majority_ids = [qid for qid, key in items if key == majority_key]
    return majority_ids[allowed:]
