"""Unicode-safe text folding for SK/CS comparisons (#168 DD13).

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
