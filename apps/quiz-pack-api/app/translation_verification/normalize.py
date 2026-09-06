"""Unicode-safe text folding for SK/CS comparisons (#168 — batch translation pipeline SK/CS, DD13).

``app.verification.answerability._normalize`` folds with ``[^a-z0-9 ]`` — on
Slovak/Czech that does not strip an accent, it DELETES the letter ("žirafa" →
"irafa"), so every diacritic-carrying answer compares as a different word.
Folding here is NFKD + drop combining marks, which maps "žirafa" → "zirafa"
and lets a model that answered without diacritics still match. English
articles are deliberately not stripped: SK/CS have none, and "a"/"an"/"the"
are meaningful token starts in neither language.
"""

from __future__ import annotations

import re
import unicodedata

_NON_WORD_RE = re.compile(r"[^\w ]+", re.UNICODE)
_SPACES_RE = re.compile(r"\s+")


def fold(text: str) -> str:
    """Casefolded, accent-folded, punctuation-free comparison form."""
    decomposed = unicodedata.normalize("NFKD", str(text).casefold())
    stripped = "".join(c for c in decomposed if not unicodedata.combining(c))
    return _SPACES_RE.sub(" ", _NON_WORD_RE.sub(" ", stripped)).strip()


def tokens(text: str, min_length: int = 3) -> set[str]:
    """Content tokens of the folded text, short function words dropped."""
    return {t for t in fold(text).split() if len(t) >= min_length}


def token_overlap(a: str, b: str) -> float:
    """Jaccard overlap of content tokens; 0.0 when either side has none."""
    ta, tb = tokens(a), tokens(b)
    if not ta or not tb:
        return 0.0
    return len(ta & tb) / len(ta | tb)


_MIN_SHARED_STEM = 4


def stem_matches(a: str, b: str) -> bool:
    """True when two folded tokens share a stem long enough to be one word.

    Slovak and Czech inflect the ending, not the stem ("satelity" /
    "satelitov", "staré" / "starých", "odpad" / "odpadu"), so the shared
    leading stem is the signal. The threshold is an absolute
    ``_MIN_SHARED_STEM`` of 4 characters rather than a percentage of the
    longer token: a percentage scales the bar with word length, so it is
    *laxest* exactly where it is most dangerous — short tokens, where four
    shared letters can be most of an unrelated word.
    """
    if not a or not b:
        return False
    shared = 0
    for char_a, char_b in zip(a, b):
        if char_a != char_b:
            break
        shared += 1
    return shared >= _MIN_SHARED_STEM


def covers_tokens(reference: str, answer: str) -> bool:
    """True when EVERY content token of ``reference`` is matched in ``answer``.

    Two guards keep the stem tolerance from becoming a false pass. All
    reference tokens must be matched, not one: "kozmický odpad" is not covered
    by "kozmické lode", because "odpad" has no counterpart even though the
    adjectives share a stem. And a single-token reference is refused outright —
    with only one token there is nothing to corroborate a stem coincidence, so
    "Fínska strana" would otherwise "cover" the answer "Fínsko". The answer may
    carry extra tokens; a model naming the answer inside a sentence is right.
    """
    ref_tokens, answer_tokens = tokens(reference), tokens(answer)
    if len(ref_tokens) < 2 or not answer_tokens:
        return False
    return all(any(stem_matches(r, a) for a in answer_tokens) for r in ref_tokens)
