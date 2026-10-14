"""Is an open answer essentially a quantity? (#202, founder 2026-10-14)

The brief tells the generator "never ask an open question whose answer is a
number" (a voice player cannot hit "Two" or "2.5 billion" by reasoning, and
speech recognition mangles numbers), yet the third dry run kept one. This is
the deterministic backstop used by ``fresh_generate.post_filter``.

An answer counts as a quantity when, after optional hedging words ("about",
"asi", "okolo"), it is a number expression, then at most ONE trailing unit
word: digits ("2", "2.5", "10 000", "1,200", "5k", "40%"), or number words in
en / sk / cs ("two", "dvadsať jeden", "dvacet", "hundred", "sto", "miliarda").
Examples: "Two", "2.5 billion dollars", "dva filmy", "about 40 %".

Deliberately NOT a quantity, so real titles survive: the number must come
first ("Apollo 13", "Penelope"); more than one trailing word ("21 Jump
Street", "Two and a Half Men"); a capitalised trailing word ("2026 Emmys",
"12 Years" may be a name — units are lowercase). A bare number-word title
("Seven", "Ten") is indistinguishable from a quantity and is dropped; the
price is one lost question, the alternative is a number-only answer.
"""

from __future__ import annotations

import re

from app.translation_verification.normalize import fold

_NUMBER_WORDS_RAW = """
zero one two three four five six seven eight nine ten eleven twelve thirteen
fourteen fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty
sixty seventy eighty ninety hundred thousand million billion trillion
nula jeden jedna jedno dva dve tri styri štyri päť šesť sedem osem deväť desať
jedenásť dvanásť trinásť štrnásť pätnásť šestnásť sedemnásť osemnásť devätnásť
dvadsať tridsať štyridsať päťdesiat šesťdesiat sedemdesiat osemdesiat
deväťdesiat sto stovka stovky tisíc tisíce milión milióny miliónov miliarda
miliardy miliárd
dvě tři čtyři pět šest sedm osm devět deset jedenáct dvanáct třináct čtrnáct
patnáct šestnáct sedmnáct osmnáct devatenáct dvacet třicet čtyřicet padesát
šedesát sedmdesát osmdesát devadesát milion miliony milionů miliard
"""
NUMBER_WORDS = frozenset(fold(w) for w in _NUMBER_WORDS_RAW.split())
_HEDGES_RAW = """
about around approximately roughly nearly almost over under
asi okolo cca približne takmer skoro viac menej ako
přibližně zhruba téměř více méně než
"""
HEDGES = frozenset(fold(w) for w in _HEDGES_RAW.split())
_DIGITS = re.compile(r"^\d+(?:[.,]\d+)*(?:k|m|mn|bn|s|st|nd|rd|th)?$", re.IGNORECASE)
_SYMBOLS = re.compile(r"[$€£~≈%+]")
_EDGE_PUNCT = ".,;:!?\"'()"


def _tokens(answer: str) -> list[str]:
    cleaned = _SYMBOLS.sub(" ", answer)
    return [t for t in (w.strip(_EDGE_PUNCT) for w in cleaned.split()) if t]


def _is_number_token(token: str) -> bool:
    return bool(_DIGITS.match(token)) or fold(token) in NUMBER_WORDS


def is_numeric_answer(answer: str) -> bool:
    """True when ``answer`` is essentially a quantity (see module docstring)."""
    tokens = _tokens(str(answer))
    while tokens and fold(tokens[0]) in HEDGES:
        tokens = tokens[1:]
    count = 0
    while count < len(tokens) and _is_number_token(tokens[count]):
        count += 1
    if count == 0:
        return False
    rest = tokens[count:]
    if not rest:
        return True
    unit = rest[0]
    return len(rest) == 1 and unit.isalpha() and unit == unit.lower()
