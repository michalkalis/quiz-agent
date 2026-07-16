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

# Founder ruling (locked, 2026-07-09): the spoken answer must stay "a few
# words" so the voice grader can judge it. The core answer (gloss excluded)
# may run to this many words before the question is a format defect
# (cocoa-butter Q35: full-sentence answer; 3-litre-jug Q9: procedure).
_ANSWER_MAX_WORDS = 6

# Units guard (#99 D3, G3 Q7 2026-07-15): the target player is a non-US,
# non-native English speaker who cannot convert imperial mid-quiz. Fahrenheit
# and mph are imperial by name and flag on their own; length/weight/volume
# units flag only next to a quantity (digits or a spelled number), which keeps
# proper nouns ("Miles Davis"), body-part feet and unit-less idioms out.
_IMPERIAL_ALWAYS_RE = re.compile(
    r"(?i)(?:°\s*F\b|\bdegrees?\s+fahrenheit\b|\bfahrenheit\b|\bmph\b)"
)
_NUMBER_WORD = (
    r"(?:\d[\d,.]*|a|an|one|two|three|four|five|six|seven|eight|nine|ten|"
    r"eleven|twelve|dozen|twenty|thirty|forty|fifty|sixty|seventy|eighty|"
    r"ninety|hundred|thousand|million|few|several)"
)
_IMPERIAL_QUANTIFIED_RE = re.compile(
    rf"(?i)\b{_NUMBER_WORD}(?:[\s-]+\w+)?[\s-]+"
    r"(?:miles?|feet|foot|inch(?:es)?|pounds?|lbs?|ounces?|gallons?|"
    r"yards?|acres?)\b"
)
# Any metric marker in the same text means the imperial figure is the
# parenthetical companion ("100 °F (38 °C)") — the sanctioned shape.
_METRIC_RE = re.compile(
    r"(?i)(?:°\s*C\b|\bdegrees?\s+celsius\b|\bcelsius\b|\bkilomet|\bkm\b|"
    r"\bmetres?\b|\bmeters?\b|\bcentimet|\bmillimet|\bcm\b|\bmm\b|"
    r"\bkilograms?\b|\bkg\b|\bgrams?\b|\blitres?\b|\bliters?\b|\btonnes?\b)"
)

# Undated-record guard (#99 D2 subset, G3 Q7): a record/first/milestone claim
# with no temporal anchor floats free — the founder asked "when?". Marker and
# anchor lists are heuristics ("record" also matches vinyl records), so this
# guard is shadow-only by contract: it must never be routed through the
# enforce gate until validated on a rated batch.
_RECORD_MARKER_RE = re.compile(
    r"(?i)\b(?:for the first time|first time|first ever|never before|"
    r"records?|record-breaking|milestones?)\b"
)
_DATE_ANCHOR_RE = re.compile(
    r"(?i)\b(?:1\d{3}|20\d{2}|\d{2,4}0s|centur(?:y|ies)|ancient|medieval|"
    r"victorian|renaissance|middle ages|bce?|ad|ce|world war)\b"
)


def _content_tokens(text: str) -> set[str]:
    return {
        t
        for t in _TOKEN_RE.findall(text.lower())
        if len(t) >= 3 and t not in _STOPWORDS
    }


# The gradable spoken answer is the part before any parenthetical gloss or
# dash/semicolon elaboration — "Paces (steps of a Roman soldier)" is graded as
# "Paces"; the gloss is post-answer context, not the answer. Guards judge the
# core only (2026-07-10 validation: gloss tokens caused leak false-positives).
_GLOSS_SPLIT_RE = re.compile(r"\s*[(\[;]|\s+[—–]\s+|\s+-\s+")

# A stem that itself poses the alternatives ("…the Marvel superhero Black
# Panther, or the Black Panther political party?") necessarily contains the
# answer — that is the format, not a leak. Detected via the ", or " offer.
_CHOICE_IN_STEM_RE = re.compile(r",\s+or\s+", re.IGNORECASE)


def _core_answer(text: str) -> str:
    core = _GLOSS_SPLIT_RE.split(text, maxsplit=1)[0].strip()
    return core or text.strip()


def stem_leak_reason(
    question: str,
    correct_answer: object,
    possible_answers: dict | None = None,
) -> str | None:
    """Reason string when the stem gives the answer away lexically, else None.

    Flags when more than half of the core answer's content words appear in
    the stem (exact token, or shared 4-char prefix for words of 6+ chars).
    MCQ is skipped: the key is a letter and option values legitimately appear
    alongside the stem — `distractor_quality` owns MCQ leak shapes. T/F is
    skipped too: every T/F stem may say "true or false", which is framing,
    not a leak — the T/F balance guard owns that format. Choice-in-stem
    questions (", or " alternatives) are skipped: the answer is one of the
    offered alternatives by design.
    """
    if possible_answers:
        return None
    if true_false_key(correct_answer) is not None:
        return None
    if _CHOICE_IN_STEM_RE.search(question):
        return None
    if isinstance(correct_answer, list):
        correct_answer = correct_answer[0] if correct_answer else ""
    core = _core_answer(str(correct_answer))
    ordered_tokens = [
        t for t in _TOKEN_RE.findall(core.lower())
        if len(t) >= 3 and t not in _STOPWORDS
    ]
    answer_tokens = set(ordered_tokens)
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

    coverage = len(leaked) / len(answer_tokens)
    # A strict majority always flags. At exactly half, flag only when the
    # answer's head token (the distinctive one in an English noun phrase —
    # "RAZOR blade") leaked; a shared trailing token ("Mortimer MOUSE" under
    # a stem about Mickey Mouse) is the subject, not a giveaway.
    if coverage > 0.5 or (coverage == 0.5 and ordered_tokens[0] in leaked):
        return f"stem_leak({','.join(sorted(leaked))})"
    return None


def long_answer_reason(
    correct_answer: object, possible_answers: dict | None = None
) -> str | None:
    """Reason string when the gradable answer is too long to speak/grade.

    Judges the *core* answer (parenthetical gloss / dash elaboration
    excluded — that is post-answer context, not what the player must say).
    MCQ is exempt (the spoken answer is a short option) and T/F is exempt
    (one word by construction).
    """
    if possible_answers:
        return None
    if true_false_key(correct_answer) is not None:
        return None
    if isinstance(correct_answer, list):
        correct_answer = correct_answer[0] if correct_answer else ""
    core = _core_answer(str(correct_answer))
    # A comma elaboration ("Astronauts on the ISS, orbiting 400 km overhead")
    # is also context, not part of the spoken answer.
    core = core.split(",", 1)[0]
    words = core.split()
    if len(words) > _ANSWER_MAX_WORDS:
        return f"long_answer({len(words)}w)"
    return None


def units_reason(
    question: str,
    correct_answer: object,
    possible_answers: dict | None = None,
) -> str | None:
    """Reason string when a figure is imperial-only, else None.

    #99 D3 (G3 Q7, founder 2026-07-15): "100 degrees Fahrenheit" — a Slovak
    player cannot convert imperial mid-quiz; metric must lead, imperial at
    most in parentheses for an iconic source figure ("100 °F (38 °C)").
    Checks stem + option values + answer as one text: any metric marker
    present passes; otherwise a Fahrenheit/mph mention or a quantified
    length/weight/volume unit flags.
    """
    parts = [question or ""]
    if possible_answers:
        parts.extend(str(v) for v in possible_answers.values())
    if isinstance(correct_answer, list):
        parts.extend(str(a) for a in correct_answer)
    elif correct_answer is not None:
        parts.append(str(correct_answer))
    text = " ".join(parts)
    if _METRIC_RE.search(text):
        return None
    m = _IMPERIAL_ALWAYS_RE.search(text) or _IMPERIAL_QUANTIFIED_RE.search(text)
    if m:
        marker = " ".join(m.group(0).split()).lower()
        return f"imperial_units({marker})"
    return None


def undated_record_reason(
    question: str, explanation: str | None = None
) -> str | None:
    """Reason string when a record/first/milestone claim has no date, else None.

    #99 D2 subset (G3 Q7): "for the first time in over 300 years … recorded
    what temperature milestone" — without a year, decade or era the record
    floats free. SHADOW-ONLY BY CONTRACT: the marker heuristic has known
    false-positive shapes ("vinyl record"), so callers must count and log
    this reason but never drop on it, regardless of ``CRAFT_GUARDS_ENFORCE``,
    until it is validated on a founder-rated batch (#99 Phase 4).
    """
    text = f"{question or ''} {explanation or ''}"
    m = _RECORD_MARKER_RE.search(text)
    if m is None:
        return None
    if _DATE_ANCHOR_RE.search(text):
        return None
    return f"undated_record({m.group(0).lower()})"


def true_false_key(
    correct_answer: object, possible_answers: dict | None = None
) -> str | None:
    """Normalized 'true'/'false' when the question is a T/F item, else None.

    Covers the corpus shapes: free-text with a True/False answer (bare, or
    annotated like "True — he voiced Mickey for ~20 years"; a punctuation
    separator is required so answers like "True North" stay non-T/F), and an
    MCQ whose two option values are exactly True and False (the key letter is
    resolved through the options).
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

    if ans in {"true", "false"}:
        return ans
    m = re.match(r"^(true|false)\s*[—–:,.;-]", ans)
    return m.group(1) if m else None


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
