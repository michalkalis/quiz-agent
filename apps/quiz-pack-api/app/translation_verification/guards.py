"""Deterministic translation guards (#168 — batch translation pipeline SK/CS, T6).

Seven no-LLM checks over ``(source_question, translated_draft, language)``. Each
returns a reason string in the ``craft_guards`` style, or ``None`` when clean.

Unlike the craft guards these are **always enforcing**: ``CRAFT_GUARDS_ENFORCE``
is never read here. Craft guards score taste (a shadow/enforce dial makes sense
for taste); these check invariants a translation cannot break and still be the
same question — a dropped digit, a flipped unit, an untranslated string, an MCQ
that lost an option. Anything subtler (fluency, register, calques) is the MQM
judge's job, so every guard here is deliberately lenient at the edges: a false
alarm blocks a correct translation, which is the expensive direction.
"""

from __future__ import annotations

import re
import unicodedata
from collections import Counter
from typing import Callable, Optional

from quiz_shared.models.question import Question

from app.scoring.craft_guards import _IMPERIAL_ALWAYS_RE, _METRIC_RE
from app.translation_verification.draft import TranslatedDraft
from app.translation_verification.normalize import fold, token_overlap

# Digit groups, separator-agnostic: "1,500" / "1 500" / "1.5" all canonicalise
# to their bare digits, so EN and SK/CS number formatting is not a defect.
_NUMBER_RE = re.compile(r"\d+(?:[., \s]\d+)*")

# Language-invariant unit markers. The craft-guard regexes below are English
# WORD patterns ("metres", "fahrenheit"), so they can only be asked about the
# English source; a Slovak draft legitimately says "metrov". Symbols survive
# translation, so they are what the draft is checked against.
_SYMBOL_UNIT_RE = re.compile(r"(?i)°\s*[CF]|\b(?:km/h|km|cm|mm|kg|mph)\b")

_PLACEHOLDER_RE = re.compile(
    r"\{[^{}]*\}|%\([^)]*\)[sdif]|%[sdif]|<[^<>\s][^<>]*>|\[\[[^\]]+\]\]"
)

_LENGTH_RATIO_MIN = 0.6
_LENGTH_RATIO_MAX = 1.8
_LENGTH_RATIO_MIN_CHARS = 20
_UNTRANSLATED_MIN_TOKENS = 4
_UNTRANSLATED_OVERLAP = 0.9


def _source_texts(question: Question) -> list[str]:
    parts = [question.question, str(question.correct_answer)]
    if question.possible_answers:
        parts.extend(str(v) for v in question.possible_answers.values())
    parts.extend(str(a) for a in (question.alternative_answers or []))
    for extra in (question.explanation, question.headline_answer):
        if extra:
            parts.append(str(extra))
    return [p for p in parts if p]


def _draft_texts(draft: TranslatedDraft) -> list[str]:
    parts = [draft.question, draft.correct_answer]
    if draft.possible_answers:
        parts.extend(str(v) for v in draft.possible_answers.values())
    parts.extend(str(a) for a in (draft.alternative_answers or []))
    for extra in (draft.explanation, draft.headline_answer):
        if extra:
            parts.append(str(extra))
    return [p for p in parts if p]


# --- 1. number / date preservation -------------------------------------------


def _numbers(text: str) -> Counter:
    return Counter(re.sub(r"\D", "", m) for m in _NUMBER_RE.findall(text))


def _anchored(value: str, others: Counter) -> bool:
    """True when ``value`` has a plausible counterpart on the other side.

    Equality, or one being a prefix/suffix of the other, so "the 1960s" →
    "60. rokoch" is not reported as a lost year while 1969 → 1996 still is.
    """
    return any(
        value == other or value.startswith(other) or other.startswith(value)
        or value.endswith(other) or other.endswith(value)
        for other in others
    )


# Slovak/Czech write centuries as ordinals — "in the 1930s" → "v 30. rokoch
# 20. storočia", "sixteenth century" → "16. storočia" — so the draft carries a
# numeral the English never spelled as a figure. First corpus run (2026-09-10):
# 18 of 20 number-guard rejections were exactly this.
_CENTURY_ORDINAL_RE = re.compile(r"\b(\d{1,2})\.\s*(?:storo|stol)")


def number_preservation_reason(
    source: Question, draft: TranslatedDraft, language: str
) -> Optional[str]:
    """Every figure (and the numerals dates carry) survives the translation."""
    src = _numbers(" ".join(_source_texts(source)))
    tgt_text = " ".join(_draft_texts(draft))
    tgt = _numbers(tgt_text)
    century_ordinals = set(_CENTURY_ORDINAL_RE.findall(tgt_text))
    missing = sorted(n for n in src if not _anchored(n, tgt))
    added = sorted(
        n for n in tgt if not _anchored(n, src) and n not in century_ordinals
    )
    if not missing and not added:
        return None
    return f"number_mismatch(missing={','.join(missing) or '-'};added={','.join(added) or '-'})"


# --- 2. unit preservation ------------------------------------------------------


def unit_preservation_reason(
    source: Question, draft: TranslatedDraft, language: str
) -> Optional[str]:
    """Unit symbols survive, and no imperial unit is invented in translation."""
    src_text = " ".join(_source_texts(source))
    tgt_text = " ".join(_draft_texts(draft))

    src_symbols = Counter(
        " ".join(m.group(0).split()).lower() for m in _SYMBOL_UNIT_RE.finditer(src_text)
    )
    tgt_symbols = Counter(
        " ".join(m.group(0).split()).lower() for m in _SYMBOL_UNIT_RE.finditer(tgt_text)
    )
    dropped = sorted(u for u, n in src_symbols.items() if tgt_symbols[u] < n)
    if dropped:
        return f"unit_dropped({','.join(dropped)})"

    # A draft may not introduce an imperial reading the English never had
    # (a "converted" mph/°F is a content change, not a translation).
    if _IMPERIAL_ALWAYS_RE.search(tgt_text) and not _IMPERIAL_ALWAYS_RE.search(src_text):
        return "unit_system_introduced(imperial)"
    # …and it may not silently convert one away either: an English "100 °F"
    # that comes back as a Celsius figure is a content change wearing a
    # translation's clothes.
    if (
        _IMPERIAL_ALWAYS_RE.search(src_text)
        and not _IMPERIAL_ALWAYS_RE.search(tgt_text)
        and _METRIC_RE.search(tgt_text)
    ):
        return "unit_system_converted(imperial_to_metric)"
    # A source that is metric only in English words ("100 metres") is NOT
    # checked for a metric marker in the draft: "100 metrov" carries none, and
    # _METRIC_RE is an English word list. Symbol drops above cover the rest.
    return None


# --- 3. untranslated string ----------------------------------------------------


def untranslated_string_reason(
    source: Question, draft: TranslatedDraft, language: str
) -> Optional[str]:
    """A translatable long field that came back as its English self.

    Only ``language_dependent=False`` questions are judged: a wordplay item is
    excluded from non-EN serving anyway, and an English fragment inside one can
    be the point. Short fields (answers, options) are skipped — a proper noun
    that is identical in Slovak is correct, not untranslated.
    """
    if source.language_dependent:
        return None
    pairs = (
        ("question", source.question, draft.question),
        ("explanation", source.explanation, draft.explanation),
    )
    for field_name, src, tgt in pairs:
        if not src or not tgt:
            continue
        src_fold, tgt_fold = fold(src), fold(tgt)
        if len(src_fold.split()) < _UNTRANSLATED_MIN_TOKENS:
            continue
        if src_fold == tgt_fold or token_overlap(src, tgt) >= _UNTRANSLATED_OVERLAP:
            return f"untranslated_string({field_name})"
    return None


# --- 4. MCQ shape --------------------------------------------------------------


def mcq_shape_reason(
    source: Question, draft: TranslatedDraft, language: str
) -> Optional[str]:
    """Same option keys and count, distinct option texts, answer key resolvable."""
    src_options = source.possible_answers or None
    tgt_options = draft.possible_answers or None
    if src_options is None and tgt_options is None:
        return None
    if src_options is None:
        return "mcq_shape(options_added)"
    if tgt_options is None:
        return "mcq_shape(options_dropped)"

    src_keys = {str(k).strip().lower() for k in src_options}
    tgt_keys = {str(k).strip().lower() for k in tgt_options}
    if len(tgt_options) != len(src_options) or src_keys != tgt_keys:
        return f"mcq_shape(option_keys_changed:{','.join(sorted(tgt_keys))})"

    seen: dict[str, str] = {}
    for key, value in tgt_options.items():
        folded = fold(str(value))
        if folded and folded in seen:
            return f"mcq_shape(duplicate_option:{seen[folded]}={key})"
        seen[folded] = str(key)

    key = draft.correct_answer_key
    if key is None:
        return "mcq_shape(correct_answer_key_missing)"
    if str(key).strip().lower() not in tgt_keys:
        return f"mcq_shape(correct_answer_key_unresolvable:{key})"
    return None


# --- 5. placeholder / markup integrity -----------------------------------------


def placeholder_integrity_reason(
    source: Question, draft: TranslatedDraft, language: str
) -> Optional[str]:
    """Format placeholders and inline markup are carried over verbatim."""
    src = Counter(_PLACEHOLDER_RE.findall(" ".join(_source_texts(source))))
    tgt = Counter(_PLACEHOLDER_RE.findall(" ".join(_draft_texts(draft))))
    missing = sorted((src - tgt).elements())
    added = sorted((tgt - src).elements())
    if not missing and not added:
        return None
    return (
        f"placeholder_mismatch(missing={','.join(missing) or '-'};"
        f"added={','.join(added) or '-'})"
    )


# --- 6. length ratio -----------------------------------------------------------


def length_ratio_reason(
    source: Question, draft: TranslatedDraft, language: str
) -> Optional[str]:
    """A field that shrank or ballooned beyond what SK/CS expansion explains.

    Catches truncation ("suchy bodliak" for a full sentence) and a translator
    that answered the question instead of translating it.
    """
    pairs = (
        ("question", source.question, draft.question),
        ("explanation", source.explanation, draft.explanation),
    )
    for field_name, src, tgt in pairs:
        if not src or len(src) < _LENGTH_RATIO_MIN_CHARS:
            continue
        ratio = len(tgt or "") / len(src)
        if ratio < _LENGTH_RATIO_MIN or ratio > _LENGTH_RATIO_MAX:
            return f"length_ratio({field_name}={ratio:.2f})"
    return None


def _foreign_letters(text: str) -> set[str]:
    """Alphabetic characters outside the Latin script."""
    return {
        ch
        for ch in text
        if ch.isalpha() and not unicodedata.name(ch, "").startswith("LATIN")
    }


def script_integrity_reason(
    source: Question, draft: TranslatedDraft, language: str
) -> Optional[str]:
    """A non-Latin letter the English source did not carry.

    Seen on the first prod smoke (2026-09-10): a Cyrillic "е" homoglyph inside
    a Slovak word, invisible on screen, mispronounced by TTS and a mismatch
    for every string comparison downstream. Letters the source itself carries
    (a Greek "π", a Cyrillic band name) stay allowed.
    """
    allowed: set[str] = set()
    for text in _source_texts(source):
        allowed |= _foreign_letters(text)
    for text in _draft_texts(draft):
        foreign = _foreign_letters(text) - allowed
        if foreign:
            sample = ", ".join(
                f"{ch!r} {unicodedata.name(ch, '?')}" for ch in sorted(foreign)[:3]
            )
            return f"script_integrity({sample})"
    return None


GUARDS: tuple[Callable[[Question, TranslatedDraft, str], Optional[str]], ...] = (
    number_preservation_reason,
    unit_preservation_reason,
    untranslated_string_reason,
    mcq_shape_reason,
    placeholder_integrity_reason,
    length_ratio_reason,
    script_integrity_reason,
)


def run_guards(
    source: Question, draft: TranslatedDraft, language: str
) -> list[str]:
    """All guard reasons for one draft — empty list means the draft is clean.

    Always enforcing: the caller blocks approval on a non-empty list, with no
    ``CRAFT_GUARDS_ENFORCE`` shadow mode to fall back to.
    """
    reasons = [guard(source, draft, language) for guard in GUARDS]
    return [r for r in reasons if r]
