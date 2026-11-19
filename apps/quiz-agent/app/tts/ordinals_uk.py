"""Ukrainian ordinals that "N." cannot mark, for TTS (#231).

Ukrainian writes most ordinals without the period, so something else says the
number is an ordinal and which case it takes:

- a suffix: "1-го травня" → "першого", "у 5-му класі" → "п'ятому",
  "у 1990-х роках" → "дев'яностих", "2-га світова" → "друга";
- a century noun, after Arabic or Roman digits: "19 століття", "XX століття",
  "у XIX ст." → "у дев'ятнадцятому столітті". "століття" is also the plural
  after 2–4 ("проіснувала 4 століття"), so there 2–4 are ordinals only when the
  context needs a genitive ("з 4 століття", "4 століття до н. е.");
- a genitive month: "8 листопада";
- a year noun or its abbreviation: "у 1969 році", "у 1969 р.", "між 1939 і 1945
  роками", "з 1939 по 1945 рік"; a year after a genitive month is genitive.

Deterministic text transform only; the displayed text keeps its digits.
"""

from __future__ import annotations

import re

from .ordinals import (
    _MONTHS_GENITIVE,
    _UK_HARD,
    _WORD_RE,
    DAT,
    F_ACC,
    F_INS,
    F_LOC,
    F_NOM,
    F_OBL,
    GEN,
    INS,
    LOC,
    M_NOM,
    N_NOM,
    PL_GEN,
    PL_INS,
    PL_NOM,
    ordinal_words,
)

# fmt: off
_HUNDRED_STEMS = {1: "сот", 2: "двохсот", 3: "трьохсот", 4: "чотирьохсот",
                  5: "п'ятисот", 6: "шестисот", 7: "семисот", 8: "восьмисот",
                  9: "дев'ятисот"}
# What a hyphenated suffix says ("5-го" → п'ятого). Pravopys writes one letter
# for a vowel ending ("5-й", "5-ї", "5-х") and two for consonant + vowel ("5-го",
# "3-тя"); common usage adds "1-ша", "2-га".
_SUFFIX_CASE = {
    **dict.fromkeys(("й", "ий", "ій"), M_NOM),  # F_LOC before "-і": "у 5-й школі"
    **dict.fromkeys(("го", "ого", "ього"), GEN),
    **dict.fromkeys(("му", "ому", "ьому"), LOC),
    **dict.fromkeys(("м", "им", "ім"), INS),
    **dict.fromkeys(("а", "я", "ша", "га", "тя", "та", "ма"), F_NOM),
    **dict.fromkeys(("е", "є", "ше", "ге", "тє", "те", "ме"), N_NOM),
    **dict.fromkeys(("ї", "ої", "ьої"), F_OBL),
    **dict.fromkeys(("у", "тю"), F_ACC),
    **dict.fromkeys(("ю", "ою", "ьою"), F_INS),  # "3-ю" is "третю": see below
    **dict.fromkeys(("х", "их", "іх"), PL_GEN),
    **dict.fromkeys(("і", "ті"), PL_NOM),
    **dict.fromkeys(("ми", "ими"), PL_INS),
}
_CENTURY_NOUNS = {"століття": GEN, "столітті": LOC, "століттю": DAT, "століттям": INS,
                  "тисячоліття": GEN, "тисячолітті": LOC, "тисячоліттю": DAT,
                  "тисячоліттям": INS}
# Plural nouns name a span ("XIX–XX століть"); after one number they count.
_CENTURY_PLURALS = {"століть": GEN, "століттях": LOC, "століттями": INS,
                    "тисячоліть": GEN, "тисячоліттях": LOC, "тисячоліттями": INS}
# "ст." spelled out: (after one number, after a span).
_CENTURY_ABBREVIATION = {GEN: ("століття", "століть"), LOC: ("столітті", "століттях"),
                         N_NOM: ("століття", "століття")}
_YEAR_NOUNS = {"рік": M_NOM, "року": GEN, "році": LOC, "роком": INS}
# "років" stays out: "1500–2000 років" is an amount.
_YEAR_PLURALS = {"роки": M_NOM, "роках": LOC, "роками": INS}
_YEAR_ABBREVIATIONS = {
    "р.": {M_NOM: "рік", GEN: "року", LOC: "році", INS: "роком"},
    "рр.": {M_NOM: "роки", GEN: "років", LOC: "роках", INS: "роками"},
}
# Prepositions taking the accusative, which for "рік" looks like the nominative
# ("по 1945 рік") and for "століття" is the neuter one ("у XXI століття").
_ACCUSATIVE = frozenset("у в по на за про через".split())
# The case a word before a year gives it; anything else (a month, "восени",
# "початку") reads as the genitive, the usual form of a bare date.
_YEAR_CASE = {
    **dict.fromkeys("у в".split(), LOC),
    **dict.fromkeys("по на за про через".split(), M_NOM),
    **dict.fromkeys("між поміж перед над під".split(), INS),
}
# Words before 2–4 + "століття" that need a genitive, so the count reading
# ("трьох століть") is impossible and the noun is an ordinal's.
_GENITIVE_CONTEXT = frozenset(
    "з із зі від до після протягом упродовж впродовж початку кінця кінці середини "
    "середині половини половині наприкінці напочатку межі".split()
)
_ROMAN = re.compile(r"X{0,3}(IX|IV|V?I{0,3})")
_ROMAN_VALUES = {"I": 1, "V": 5, "X": 10}
# fmt: on

_JOIN = r"(?P<join>\s*[–—-]\s*|\s+(?:і|й|та|або|чи|до|по)\s+)"
# A bare number dashed to a suffixed one shares its case: "у 1960–1970-х роках".
_SUFFIX_RE = re.compile(
    r"(?<![\d.,])(?:(?P<n1>\d{1,4})(?P<join>\s*[–—-]\s*))?"
    r"(?P<n>\d{1,4})[-‑](?P<suffix>[^\W\d_]{1,4})(?![\w'ʼ’-])"
)
_CENTURY_RE = re.compile(
    rf"(?<![\w.,])(?P<n1>[IVXІХ]+|\d{{1,2}})(?:{_JOIN}(?P<n2>[IVXІХ]+|\d{{1,2}}))?"
    r"(?P<gap>\s+)(?P<noun>ст\.|(?:столітт|тисячолітт)[^\W\d_]*|століть|тисячоліть)"
    r"(?![^\W\d_])"
)
_ERA_RE = re.compile(r"\s*(?:до\s+)?(?:н\.\s?е\.|нашої\s+ери)")
_MONTH_RE = re.compile(
    rf"(?<![\d.,])(?P<n1>\d{{1,2}})(?:{_JOIN}(?P<n2>\d{{1,2}}))?(?P<gap>\s+)"
    r"(?P<noun>[^\W\d_]+)"
)
_YEAR = r"[12]\d{3}"
_YEAR_RE = re.compile(
    rf"(?<![\d.,])(?P<n1>{_YEAR})(?:{_JOIN}(?P<n2>{_YEAR}))?(?P<gap>\s+)"
    r"(?P<noun>рр\.|р\.|[^\W\d_]+)"
)
_DATE_YEAR_RE = re.compile(
    rf"(?<=\s)(?P<month>[^\W\d_]+)(?P<gap>\s+)(?P<year>{_YEAR})(?![\d.,]\d)"
)


def uk_year_words(n: int, case: str) -> str | None:
    """1969 → "тисяча дев'ятсот шістдесят дев'ятий" in ``case``; a round year
    fuses into one word: 1900 → "тисяча дев'ятисотий", 2000 → "двохтисячний",
    2100 → "дві тисячі сотий"."""
    if not (1000 <= n <= 2999):
        return None
    if n % 100 == 0:
        ending = _UK_HARD[case]
        if n == 2000:
            return f"двохтисячн{ending}"
        if n == 1000:
            return f"тисячн{ending}"
        thousand = "тисяча" if n < 2000 else "дві тисячі"
        return f"{thousand} {_HUNDRED_STEMS[n // 100 % 10]}{ending}"
    from num2words import num2words

    head = num2words(n - n % 100, lang="uk").replace("одна тисяча", "тисяча")
    return f"{head} {ordinal_words(n % 100, 'uk', case)}"


def uk_ordinal(n: int, case: str) -> str | None:
    """1–2999 as a declined ordinal; only the last word declines ("сто
    двадцять п'ятий"), round hundreds fuse ("двохсотий"). None above."""
    if n <= 100:
        return ordinal_words(n, "uk", case)
    if n >= 1000:
        return uk_year_words(n, case)
    if n % 100 == 0:
        return _HUNDRED_STEMS[n // 100] + _UK_HARD[case]
    from num2words import num2words

    return f"{num2words(n - n % 100, lang='uk')} {ordinal_words(n % 100, 'uk', case)}"


def _word_before(text: str, start: int) -> str:
    words = _WORD_RE.findall(text[max(0, start - 40) : start])
    return words[-1].lower() if words else ""


def _word_after(text: str, end: int) -> str:
    words = _WORD_RE.findall(text[end : end + 40])
    return words[0].lower() if words else ""


def _abbreviation_period(text: str, end: int) -> str:
    """Keep an abbreviation's period when it also ends the sentence."""
    rest = text[end:].lstrip()
    return "." if not rest or rest[0].isupper() else ""


def _roman(token: str) -> int | None:
    if token == "І":
        return None  # a lone Cyrillic "І" is the word "and", not Roman one
    token = token.replace("І", "I").replace("Х", "X")  # typed in Cyrillic
    if not token or not _ROMAN.fullmatch(token):
        return None
    values = [_ROMAN_VALUES[ch] for ch in token]
    return sum(-v if v < nxt else v for v, nxt in zip(values, values[1:] + [0]))


def _number(token: str) -> int | None:
    return int(token) if token.isdigit() else _roman(token)


def _spell_span(match: re.Match, case: str, noun: str, spell) -> str:
    """ "N noun", or a span "N–M noun" / "з N по M noun", read in ``case``;
    after "з … до/по" the first number keeps its own genitive."""
    numbers = [_number(match["n1"])] + ([_number(match["n2"])] if match["n2"] else [])
    first_case = GEN if match["n2"] and match["join"].strip() in ("до", "по") else case
    cases = [first_case, case] if match["n2"] else [case]
    words = [spell(n, c) if n else None for n, c in zip(numbers, cases)]
    if None in words:
        return match.group(0)
    join = match["join"] or ""
    join = " – " if join.strip() in ("–", "—", "-") else join  # a spoken pause
    head = f"{words[0]}{join}{words[1]}" if len(words) == 2 else words[0]
    return f"{head}{match['gap']}{noun}"


def _governor(match: re.Match) -> str:
    """The word that sets the noun's case: "до"/"по" inside a span, else the
    word before the first number."""
    join = (match["join"] or "").strip() if match["n2"] else ""
    return join if join in ("до", "по") else _word_before(match.string, match.start())


def _spell_suffixes(text: str) -> str:
    def replace(match: re.Match) -> str:
        suffix = match["suffix"].lower()
        case = _SUFFIX_CASE.get(suffix)
        if case is None:
            return match.group(0)
        if case == M_NOM and _word_after(match.string, match.end()).endswith(
            ("і", "ї")
        ):
            case = F_LOC  # "у 5-й школі", "на 2-й лінії"

        def spell(n: int) -> str | None:
            if suffix == "ю" and n % 10 == 3 and n % 100 != 13:
                return uk_ordinal(n, F_ACC)  # "3-ю" is "третю"; "5-ю" is "п'ятою"
            return uk_ordinal(n, case)

        last = spell(int(match["n"]))
        if last is None:
            return match.group(0)
        if not match["n1"]:
            return last
        first = spell(int(match["n1"]))
        if first is None:
            return match.group(0)
        return f"{first} – {last}"  # a spoken pause, as in _spell_span

    return _SUFFIX_RE.sub(replace, text)


def _century_case(match: re.Match) -> tuple[str, str] | None:
    """(case, noun as spoken) for a century match, None to leave it a count."""
    noun, low, governor = match["noun"], match["noun"].lower(), _governor(match)
    span = bool(match["n2"]) and match["join"].strip() not in ("до", "по")
    # "Правильна відповідь: XIX століття": an answer or a label names the
    # century in the nominative, "дев'ятнадцяте". After "відповідь" (the
    # feedback line) 2–4 are ordinals too; after another label ("Тривалість:
    # 3 століття") they may still count.
    named = governor == "відповідь" or (
        match.string[: match.start()].rstrip().endswith(":")
    )
    if low == "ст.":
        case = (
            LOC
            if governor in ("у", "в")
            else N_NOM
            if governor in _ACCUSATIVE or named
            else GEN
        )
        period = _abbreviation_period(match.string, match.end())
        return case, _CENTURY_ABBREVIATION[case][span] + period
    if low in _CENTURY_PLURALS:
        return (_CENTURY_PLURALS[low], noun) if span else None  # "5 століть"
    case = _CENTURY_NOUNS.get(low)
    if case != GEN:
        return (case, noun) if case else None
    if governor == "відповідь":
        return N_NOM, noun  # "Відповідь: 3 століття" is "третє"
    # "століття" is also the accusative and the plural after 2–4.
    if governor in _ACCUSATIVE or named:
        case = N_NOM  # "у XXI століття", "по XVII століття", "Період: XIX століття"
    n = int(match["n1"]) if match["n1"].isdigit() and not match["n2"] else None
    if n and 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14:
        era = _ERA_RE.match(match.string, match.end())
        if governor not in _GENITIVE_CONTEXT and not era:
            return None  # "проіснувала 4 століття", "через 2 тисячоліття"
    return case, noun


def _spell_centuries(text: str) -> str:
    def replace(match: re.Match) -> str:
        found = _century_case(match)
        if found is None:
            return match.group(0)
        return _spell_span(match, *found, lambda n, c: ordinal_words(n, "uk", c))

    return _CENTURY_RE.sub(replace, text)


def _spell_months(text: str) -> str:
    """ "8 листопада" and a span "1–5 травня" / "з 1 по 5 травня": genitive,
    but "по" takes the accusative ("по п'яте травня")."""

    def replace(match: re.Match) -> str:
        if match["noun"].lower() not in _MONTHS_GENITIVE["uk"]:
            return match.group(0)
        case = N_NOM if match["n2"] and match["join"].strip() == "по" else GEN
        return _spell_span(
            match,
            case,
            match["noun"],
            lambda n, c: ordinal_words(n, "uk", c) if 1 <= n <= 31 else None,
        )

    return _MONTH_RE.sub(replace, text)


def _spell_years(text: str) -> str:
    def by_noun(match: re.Match) -> str:
        noun, low = match["noun"], match["noun"].lower()
        if low in _YEAR_ABBREVIATIONS:
            case = _YEAR_CASE.get(_governor(match), GEN)
            period = _abbreviation_period(match.string, match.end())
            noun = _YEAR_ABBREVIATIONS[low][case] + period
        elif low in _YEAR_NOUNS:
            case = _YEAR_NOUNS[low]
        elif match["n2"] and low in _YEAR_PLURALS:
            case = _YEAR_PLURALS[low]
        else:
            return match.group(0)
        return _spell_span(match, case, noun, uk_year_words)

    def after_month(match: re.Match) -> str:
        if match.group("month").lower() not in _MONTHS_GENITIVE["uk"]:
            return match.group(0)
        spelled = uk_year_words(int(match.group("year")), GEN)
        if not spelled:
            return match.group(0)
        return f"{match.group('month')}{match.group('gap')}{spelled}"

    return _DATE_YEAR_RE.sub(after_month, _YEAR_RE.sub(by_noun, text))


def spell_uk_ordinals(text: str) -> str:
    """Every Ukrainian ordinal marked by a suffix, a century, a month or a year."""
    text = _spell_suffixes(text)
    text = _spell_centuries(text)
    text = _spell_months(text)
    return _spell_years(text)
