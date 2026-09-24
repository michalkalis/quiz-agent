"""Deterministic sound-alike check for spoken open answers (#185 track E).

Answers are transcribed in a moving car with the recogniser pinned to the quiz
language, so a foreign answer comes back respelled the way it sounds: the
founder's car test (2026-09-23) said "curling" and got "Carling" — a beer brand
the LLM judge then treated as a different answer. This module recognises the
clearest of those cases without an LLM call.

It may only ever say "this is the right answer". Anything it does not accept
goes on to the LLM judge unchanged, so a miss here costs nothing but a call.
A false accept, on the other hand, awards a point for a wrong answer — so the
rules are deliberately narrow:

- **Spelling variants** — the two strings are identical once spelling that
  does not change the sound is canonicalised ("Kuba"/"Cuba", "Otava"/"Ottawa",
  "Filip"/"Philip", doubled letters).
- **One vowel slip inside a long word** — exactly one vowel swapped, dropped or
  added, never at the first or last letter, in a word of at least six letters
  ("Carling"/"curling", "Hungry"/"Hungary"). Consonants carry a word's
  identity; distinct short names are routinely one vowel apart
  ("Monet"/"Manet", "Lenin"/"Lennon"), and endings carry meaning
  ("Albany"/"Albania"), hence the length and position limits.
- **Numbers and short words never bend** — digits, roman numerals and words
  under three letters must match exactly ("Henry VII" is not "Henry VIII").
"""

from __future__ import annotations

import re
import unicodedata
from typing import Iterable

_VOWELS = frozenset("aeiou")
_ROMAN_NUMERAL = re.compile(r"^m{0,4}(cm|cd|d?c{0,3})(xc|xl|l?x{0,3})(ix|iv|v?i{0,3})$")
# Spelling that does not change the sound (applied in order, on folded text).
_SPELLING_RULES = (
    ("ph", "f"),
    ("th", "t"),
    ("ck", "k"),
    ("qu", "kv"),
    ("q", "k"),
    ("w", "v"),
    ("x", "ks"),
    ("y", "i"),
)
_MIN_FUZZY_WORD_LEN = 6


def fold(text: str) -> str:
    """Casefold, strip diacritics, turn every non-word run into one space.

    ``štyri`` → ``styri``, ``Béčko!`` → ``becko``. Slovak and Czech diacritics
    are unreliable in transcripts (and irrelevant to how a word sounds), so
    every spoken-answer comparison runs on this form.
    """
    decomposed = unicodedata.normalize("NFKD", text.casefold())
    stripped = "".join(ch for ch in decomposed if not unicodedata.combining(ch))
    return " ".join(re.sub(r"[\W_]+", " ", stripped).split())


def edit_distance(a: str, b: str) -> int:
    """Levenshtein distance over one rolling row (spoken answers are short)."""
    if not a:
        return len(b)
    if not b:
        return len(a)
    row = list(range(len(b) + 1))
    for i, ca in enumerate(a, start=1):
        previous, row[0] = row[0], i
        for j, cb in enumerate(b, start=1):
            current = min(row[j] + 1, row[j - 1] + 1, previous + (ca != cb))
            previous, row[j] = row[j], current
    return row[len(b)]


def similarity(a: str, b: str) -> float:
    """1 − edit distance / longer length: 1.0 identical, 0.0 unrelated."""
    longer = max(len(a), len(b))
    if longer == 0:
        return 1.0
    return 1.0 - edit_distance(a, b) / longer


def _is_numeral(token: str) -> bool:
    if any(ch.isdigit() for ch in token):
        return True
    return bool(_ROMAN_NUMERAL.match(token))


def _canonical(token: str) -> str:
    """The token spelled by sound: spelling-only differences removed."""
    for source, target in _SPELLING_RULES:
        token = token.replace(source, target)
    # A hard "c" (before a back vowel, a consonant or at the end) is a "k";
    # before e/i it is a different sound in every language we serve.
    token = re.sub(r"c(?=[aou]|[^aeiou]|$)", "k", token)
    # Doubled letters are spelling, not sound ("Kennedy"/"Kenedy").
    return re.sub(r"(.)\1+", r"\1", token)


def _one_inner_vowel_edit(heard: str, expected: str) -> bool:
    """Exactly one vowel swapped / dropped / added, away from both word ends."""
    if min(len(heard), len(expected)) < _MIN_FUZZY_WORD_LEN:
        return False
    if len(heard) == len(expected):
        diffs = [i for i, (a, b) in enumerate(zip(heard, expected)) if a != b]
        if len(diffs) != 1:
            return False
        i = diffs[0]
        return (
            0 < i < len(expected) - 1 and heard[i] in _VOWELS and expected[i] in _VOWELS
        )
    if abs(len(heard) - len(expected)) != 1:
        return False
    longer, shorter = (
        (heard, expected) if len(heard) > len(expected) else (expected, heard)
    )
    for i in range(1, len(longer) - 1):
        if longer[i] in _VOWELS and longer[:i] + longer[i + 1 :] == shorter:
            return True
    return False


def sounds_like(heard: str, expected: str) -> bool:
    """High-confidence "the player said the expected answer" — never a rejection."""
    heard_tokens = fold(heard).split()
    expected_tokens = fold(expected).split()
    if not heard_tokens or len(heard_tokens) != len(expected_tokens):
        return False
    for h, e in zip(heard_tokens, expected_tokens):
        if (_is_numeral(h) or _is_numeral(e)) and h != e:
            return False
        # Letters and two-letter words carry no sound to be lenient about
        # ("Vitamin Q" is not "Vitamin K").
        if min(len(h), len(e)) < 3 and h != e:
            return False

    heard_canon = [_canonical(t) for t in heard_tokens]
    expected_canon = [_canonical(t) for t in expected_tokens]
    if heard_canon == expected_canon:
        return True

    differing = [(h, e) for h, e in zip(heard_canon, expected_canon) if h != e]
    return len(differing) == 1 and _one_inner_vowel_edit(*differing[0])


def sounds_like_any(heard: str, candidates: Iterable[str]) -> bool:
    return any(sounds_like(heard, c) for c in candidates if c)
