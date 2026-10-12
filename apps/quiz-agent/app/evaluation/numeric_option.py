"""Is an MCQ option a number? — decides the 1–4 vs A–D label scheme (#200).

Founder rule (2026-09-24, #185): options are labelled 1–4; letters A–D only
when the answers themselves are numbers, so "dva" can never mean both "option
2" and the answer "2 milióny". Until #200 any digit anywhere counted, so
"Apollo 11" / "Gemini 7" flipped a question about spacecraft to letters.
Founder decision 2026-10-12: keep the rule, narrow what "a number" is.

An option is numeric when it carries a number (digits or a number word) and
nothing substantive remains once numbers, number words, magnitude and unit
words ("tisíc", "milióny", "rokov", "%", "km") and approximators / connectors
("približne", "přibližně", "about", "cca", "viac ako") are removed. "Apollo 11"
keeps "apollo", so it is a name, not a number.

All vocabulary is folded (lowercase, no diacritics) and covers sk / cs / en,
because the scheme is computed on whatever language the options are served in.
"""

from __future__ import annotations

import re
from functools import lru_cache

from .voice_match import fold

# fmt: off
# Cardinals, teens, tens, hundreds — sk / cs / en, common declined forms.
_NUMBER_WORDS = frozenset(
    """
    nula zero
    jeden jedna jedno jednu jedneho jednom dva dve dvoch dvom dvoma dvou dvema
    tri troch trom tromi trech styri styroch styrom ctyri ctyr ctyrech
    piatich sest siestich sesti sedem siedmich sedm sedmi osem osmich osm osmi
    devat deviatich devet devitich desat desiatich deset deseti
    jedenast dvanast trinast strnast patnast sestnast sedemnast osemnast devatnast
    jedenact dvanact trinact ctrnact patnact sestnact sedmnact osmnact devatenact
    dvadsat tridsat styridsat patdesiat sestdesiat sedemdesiat osemdesiat devatdesiat
    dvacet tricet ctyricet padesat sedesat sedmdesat osmdesat devadesat
    sto dvesto tristo styristo stovky stoviek stovek
    one two three four five six seven eight nine ten eleven twelve thirteen
    fourteen fifteen sixteen seventeen eighteen nineteen twenty thirty forty
    fifty sixty seventy eighty ninety hundred hundreds dozen dozens
    tisic tisice tisicov tisicich tisicu thousand thousands
    milion miliony milionov milionu miliona milionmi million millions mln
    miliarda miliardy miliard miliardu billion billions mld bn
    bilion biliony bilionov bilionu trillion trillions
    """.split()
)
# Real words as often as numbers ("Pat", "Pet", "Set", sk "pol"): a number
# only beside another number-ish token ("pět set", "pol milióna", "asi päť").
_WEAK_NUMBER_WORDS = frozenset("pat pet set ste pol half".split())
# Units and measure words: a number's company, never a number on their own.
_UNIT_WORDS = frozenset(
    """
    rok roky rokov rokmi roku rokoch let lety letech leta year years
    mesiac mesiace mesiacov mesiacmi mesic mesice mesicu month months
    tyzden tyzdne tyzdnov tyden tydny tydnu week weeks
    den dni dna dnu dnoch day days hodina hodiny hodin hodinu hour hours h
    minuta minuty minut minutu minute minutes min
    sekunda sekundy sekund sekundu second seconds s
    storocie storocia storoci storocim stoleti stoletich century centuries
    percento percenta percent percentage procento procenta procent
    eur euro eura euros dolar dolare dolarov dolaru dollar dollars usd
    korun koruna koruny kc czk libra libier liber pound pounds
    m km cm mm meter metre metrov metru metry meters metres kilometer kilometre
    kilometrov kilometru kilometry kilometers kilometres mile miles mi
    g kg t ton tona tony tonne tonnes tons gram gramov gramu grams kilogram
    kilogramov kilogramu kilograms l ml liter litre litrov litru litry liters litres
    stupen stupne stupnov stupnu degree degrees c f
    ludi lidi people obyvatelov obyvatel osob osoby persons
    krat times kus kusy kusov kusu ks x k
    """.split()
)
# Approximators and connectors that carry no answer of their own.
_FILLER_WORDS = frozenset(
    """
    priblizne pribl asi cca zhruba okolo kolem takmer temer skoro vyse viac vice
    nez ako menej mene aspon najmenej nejmene presne len jen iba
    do od az a medzi mezi nad pod pres cez za na po pred v vo ve
    about around approximately approx roughly circa ca almost nearly over under
    more less than at least most exactly just only up to from between and an in
    ago per
    """.split()
)
# Glued suffixes on a digit run: "3rd", "19th"; units cover "5km", "1990s", "20x".
_ORDINAL_SUFFIXES = frozenset({"st", "nd", "rd", "th"})
# fmt: on

_DIGITS_WITH_SUFFIX = re.compile(r"^(\d+)([a-z]*)$")
_INFIX = "a"  # cs "pět-a-dvacet" (petadvacet): units + "a" + tens


@lru_cache(maxsize=512)
def _compound_number(token: str) -> bool:
    """Glued number words: sk "dvadsaťpäť", "dvestotisíc", cs "pětadvacet"."""
    pieces = _NUMBER_WORDS | _WEAK_NUMBER_WORDS
    n = len(token)
    reach = [False] * (n + 1)  # a number word ends exactly here
    after_infix = [False] * (n + 1)  # an "a" ends here — must be followed
    reach[0] = True
    for i in range(n):
        if not (reach[i] or after_infix[i]):
            continue
        for piece in pieces:
            if token.startswith(piece, i):
                reach[i + len(piece)] = True
        if reach[i] and i > 0 and token[i] == _INFIX:
            after_infix[i + 1] = True
    return reach[n]


def _token_kind(token: str) -> str:
    """``number`` / ``weak`` / ``neutral`` (unit, filler) / ``word``."""
    digits = _DIGITS_WITH_SUFFIX.match(token)
    if digits:
        suffix = digits.group(2)
        if not suffix or suffix in _UNIT_WORDS or suffix in _ORDINAL_SUFFIXES:
            return "number"
        return "word"
    if token in _NUMBER_WORDS:
        return "number"
    if token in _WEAK_NUMBER_WORDS:
        return "weak"
    if token in _UNIT_WORDS or token in _FILLER_WORDS:
        return "neutral"
    if len(token) >= 6 and _compound_number(token):
        return "number"
    return "word"


def is_numeric_option(value: str) -> bool:
    """True when the option IS a number (a year, count or amount), not a name
    that merely contains one — "1918", "Približne 200 tisíc", "2 milióny",
    "20 %", "5 rokov" are numbers; "Apollo 11", "Gemini 7" are not."""
    tokens = fold(value).split()
    if not tokens:
        return False
    kinds = [_token_kind(t) for t in tokens]
    if "word" in kinds:
        return False
    if "number" in kinds:
        return True
    # Only weak number words: "pět set" is a number, a lone "Pat" a name.
    return "weak" in kinds and len(tokens) >= 2
