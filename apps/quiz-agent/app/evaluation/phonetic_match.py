"""Phonetic key tier for spoken open answers (#204.6).

Sits between ``voice_match.sounds_like_any`` and the LLM judge. It compares a
rough sk/cs/en *pronunciation key* ("Vašington" and "Washington" both become
"vasinkton"), so a transcript spelled the way the recogniser heard a name still
matches the answer spelled the way the question author wrote it.

Like ``voice_match`` it may only ever say "correct"; anything it declines goes
on to the LLM judge. A false accept awards a point for a wrong answer, so:
numbers and roman numerals never bend, words under three letters must match
exactly, and a transcript whose key is a known wrong option's key is refused.
Behind ``ANSWER_PHONETIC_MATCH`` (default off) until measured on car replays.
"""

from __future__ import annotations

import re
from typing import Iterable

from .voice_match import _is_numeral, fold

# Applied in order on folded text (diacritics already gone: š→s, č→c, ý→y).
_RULES = (
    ("sch", "s"),
    ("sh", "s"),  # sh → š → s
    ("ph", "f"),
    ("th", "t"),
    ("ch", "h"),  # sk/cs "ch" is /x/
    ("ck", "k"),
    ("qu", "kv"),
    ("q", "k"),
    ("w", "v"),
    ("x", "ks"),
    ("y", "i"),
)
# Final consonants lose their voicing (cs/sk devoicing): Praha-style words
# compare by the voiceless partner.
_FINAL_DEVOICE = {"b": "p", "d": "t", "g": "k", "v": "f", "z": "s"}


def phonetic_key(token: str) -> str:
    """Pronunciation key of one folded token."""
    for source, target in _RULES:
        token = token.replace(source, target)
    # Hard "c" (before a back vowel, a consonant or at the end) is a "k".
    token = re.sub(r"c(?=[aou]|[^aeiou]|$)", "k", token)
    token = re.sub(r"(.)\1+", r"\1", token)  # doubled letters are spelling
    if token and token[-1] in _FINAL_DEVOICE:
        token = token[:-1] + _FINAL_DEVOICE[token[-1]]
    return token


def _keys(text: str) -> list[str] | None:
    """Keys per word, or None when the text must never use this tier."""
    tokens = fold(text).split()
    if not tokens:
        return None
    if any(_is_numeral(t) for t in tokens):
        return None
    return [phonetic_key(t) for t in tokens]


def phonetic_matches(
    heard: str, expected: Iterable[str], distractors: Iterable[str] = ()
) -> bool:
    """True when ``heard`` has the same key as one expected answer and as no
    distractor (a wrong MCQ option that merely sounds alike)."""
    heard_keys = _keys(heard)
    if heard_keys is None:
        return False
    heard_words = fold(heard).split()
    for wrong in distractors:
        if wrong and _keys(wrong) == heard_keys:
            return False
    for answer in expected:
        if not answer:
            continue
        keys = _keys(answer)
        if keys is None or keys != heard_keys:
            continue
        # Letters and two-letter words carry no sound to be lenient about.
        pairs = zip(heard_words, fold(answer).split())
        if all(h == e or min(len(h), len(e)) >= 3 for h, e in pairs):
            return True
    return False
