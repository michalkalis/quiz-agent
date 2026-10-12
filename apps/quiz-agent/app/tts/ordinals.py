"""Spell Slovak / Czech ordinals ("19. storočí", "1. mája") for TTS (#200).

A digit followed by a period and a lowercase word is an ordinal in sk/cs. The
cardinal pass in ``number_normalization`` used to read it as a cardinal and keep
the period — "v devätnásť. storočí", "jeden. mája" — a wrong word plus a
sentence-end pause mid-sentence. num2words has no sk/cs ordinals, so they are
built here, declined in the case the following word asks for:

- dates: "1. mája" → "prvého mája", cs "8. května" → "osmého května";
  nominative months ("1. máj") → "prvý máj"; numeric "1. 1. 2026" →
  "prvého januára 2026";
- centuries: sk by the noun's own form ("v 19. storočí" → "devätnástom");
  cs "století" does not show its case, so the preposition before the number
  decides ("v 19. století" → "devatenáctém", "do 19. století" → "devatenáctého");
- otherwise an adjective after the ordinal sets the case it agrees with
  ("2. svetovej vojny" → "druhej"), a neuter noun ending the neuter form
  ("3. miesto" → "tretie");
- anything else falls back to the masculine nominative — a real ordinal word,
  never "number-period". Above 100, the cardinal without the period.

Deterministic text transform only; the displayed text keeps its digits.
"""

from __future__ import annotations

import re

# Case slots an ordinal can take here (fem gen/dat/loc share one form).
M_NOM, F_NOM, N_NOM = "m_nom", "f_nom", "n_nom"
GEN, DAT, LOC, INS = "gen", "dat", "loc", "ins"
F_OBL, F_ACC, F_INS, PL_GEN = "f_obl", "f_acc", "f_ins", "pl_gen"

# fmt: off
# Ordinal stems for 1–10, the teens, the tens and 100 (+ whether the stem ends
# in a long syllable: Slovak then shortens the ending, "piaty" not "piatý").
_SK_STEMS = {
    1: ("prv", False), 2: ("druh", False), 4: ("štvrt", False), 5: ("piat", True),
    6: ("šiest", True), 7: ("siedm", True), 8: ("ôsm", True), 9: ("deviat", True),
    10: ("desiat", True), 11: ("jedenást", True), 12: ("dvanást", True),
    13: ("trinást", True), 14: ("štrnást", True), 15: ("pätnást", True),
    16: ("šestnást", True), 17: ("sedemnást", True), 18: ("osemnást", True),
    19: ("devätnást", True), 20: ("dvadsiat", True), 30: ("tridsiat", True),
    40: ("štyridsiat", True), 50: ("päťdesiat", True), 60: ("šesťdesiat", True),
    70: ("sedemdesiat", True), 80: ("osemdesiat", True), 90: ("deväťdesiat", True),
    100: ("st", False),
}
_SK_LONG = {M_NOM: "ý", F_NOM: "á", N_NOM: "é", GEN: "ého", DAT: "ému", LOC: "om",
            INS: "ým", F_OBL: "ej", F_ACC: "ú", F_INS: "ou", PL_GEN: "ých"}
_SK_SHORT = {M_NOM: "y", F_NOM: "a", N_NOM: "e", GEN: "eho", DAT: "emu", LOC: "om",
             INS: "ym", F_OBL: "ej", F_ACC: "u", F_INS: "ou", PL_GEN: "ych"}
_SK_TRETI = {M_NOM: "tretí", F_NOM: "tretia", N_NOM: "tretie", GEN: "tretieho",
             DAT: "tretiemu", LOC: "treťom", INS: "tretím", F_OBL: "tretej",
             F_ACC: "tretiu", F_INS: "treťou", PL_GEN: "tretích"}

_CS_HARD_STEMS = {
    2: "druh", 4: "čtvrt", 5: "pát", 6: "šest", 7: "sedm", 8: "osm", 9: "devát",
    10: "desát", 11: "jedenáct", 12: "dvanáct", 13: "třináct", 14: "čtrnáct",
    15: "patnáct", 16: "šestnáct", 17: "sedmnáct", 18: "osmnáct",
    19: "devatenáct", 20: "dvacát", 30: "třicát", 40: "čtyřicát", 50: "padesát",
    60: "šedesát", 70: "sedmdesát", 80: "osmdesát", 90: "devadesát", 100: "st",
}
_CS_SOFT_STEMS = {1: "prvn", 3: "třet"}
_CS_HARD = {M_NOM: "ý", F_NOM: "á", N_NOM: "é", GEN: "ého", DAT: "ému", LOC: "ém",
            INS: "ým", F_OBL: "é", F_ACC: "ou", F_INS: "ou", PL_GEN: "ých"}
_CS_SOFT = {M_NOM: "í", F_NOM: "í", N_NOM: "í", GEN: "ího", DAT: "ímu", LOC: "ím",
            INS: "ím", F_OBL: "í", F_ACC: "í", F_INS: "í", PL_GEN: "ích"}

_MONTHS_GENITIVE = {
    "sk": "januára februára marca apríla mája júna júla augusta septembra "
          "októbra novembra decembra".split(),
    "cs": "ledna února března dubna května června července srpna září října "
          "listopadu prosince".split(),
}
# Nouns whose own form gives the case.
_KNOWN_NOUNS = {
    "sk": {
        **dict.fromkeys(_MONTHS_GENITIVE["sk"], GEN),
        **dict.fromkeys(
            "január február marec apríl máj jún júl august september október "
            "november december".split(), M_NOM),
        **dict.fromkeys(["storočie", "tisícročie"], N_NOM),
        **dict.fromkeys(["storočia", "tisícročia"], GEN),
        **dict.fromkeys(["storočiu", "tisícročiu"], DAT),
        **dict.fromkeys(["storočí", "tisícročí"], LOC),
        **dict.fromkeys(["storočím", "tisícročím"], INS),
    },
    "cs": {
        **dict.fromkeys(_MONTHS_GENITIVE["cs"], GEN),
        **dict.fromkeys(
            "leden únor březen duben květen červen červenec srpen říjen listopad "
            "prosinec".split(), M_NOM),
        **dict.fromkeys(["stoletím", "tisíciletím"], INS),
    },
}
# Czech nouns that look the same in every singular case but the instrumental:
# the word BEFORE the ordinal decides.
_CS_CASELESS = frozenset({"století", "tisíciletí"})
_CS_PREPOSITION_CASE = {
    **dict.fromkeys("v ve na o po při".split(), LOC),
    **dict.fromkeys("do od ode z ze u během kolem okolo podle místo".split(), GEN),
    **dict.fromkeys("k ke kvůli díky proti vůči".split(), DAT),
    **dict.fromkeys("před nad pod mezi s se".split(), INS),
    # "na počátku 20. století": a noun before it governs the genitive.
    **dict.fromkeys(
        "začátku začátkem počátku počátkem konce koncem polovině polovina "
        "přelomu průběhu".split(), GEN),
}
# Adjective endings after the ordinal → the case it agrees with (longest first).
_ADJECTIVE_ENDINGS = {
    "sk": [("ieho", GEN), ("iemu", DAT), ("ého", GEN), ("eho", GEN), ("ému", DAT),
           ("emu", DAT), ("ých", PL_GEN), ("ej", F_OBL), ("ou", F_INS),
           ("ým", INS), ("á", F_NOM), ("é", N_NOM), ("ú", F_ACC), ("ý", M_NOM)],
    "cs": [("ího", GEN), ("ímu", DAT), ("ého", GEN), ("ému", DAT), ("ých", PL_GEN),
           ("ém", LOC), ("ým", INS), ("ou", F_INS), ("á", F_NOM), ("é", N_NOM),
           ("ý", M_NOM)],
}
# Neuter nouns in the nominative ("3. miesto", "10. výročie", cs "1. kolo").
_NEUTER_ENDINGS = {"sk": ("ie", "o"), "cs": ("o",)}
# Words that join ordinals: "1. a 2. svetová vojna" — look past them.
_JOINERS = frozenset("a alebo aj i až či nebo".split())
# fmt: on

# "19." followed by whitespace and a word (group 2: its first letter; a
# capital means the period ended a sentence). A word followed by a colon is a
# label ("a: 5. b: 7." — MCQ options read aloud), not what the number counts.
_ORDINAL_RE = re.compile(r"(?<![\d.,])(\d{1,3})\.(?=\s+([^\W\d_]))(?!\s+\w+:)")
_WORD_RE = re.compile(r"[^\W\d_]+|\d+\.")
# A numeric date "1. 1. 2026" / "8.5.1945": day + month, read as words.
_NUMERIC_DATE_RE = re.compile(r"(?<![\d.,])(\d{1,2})\.\s?(\d{1,2})\.(?=\s|\d|$)")


def _sk_word(n: int, case: str) -> str:
    if n == 3:
        return _SK_TRETI[case]
    stem, long_stem = _SK_STEMS[n]
    return stem + (_SK_SHORT if long_stem else _SK_LONG)[case]


def _cs_word(n: int, case: str) -> str:
    if n in _CS_SOFT_STEMS:
        return _CS_SOFT_STEMS[n] + _CS_SOFT[case]
    return _CS_HARD_STEMS[n] + _CS_HARD[case]


def ordinal_words(n: int, language: str, case: str) -> str | None:
    """1–100 as a declined ordinal ("dvadsiateho prvého"); None outside it."""
    word = _sk_word if language == "sk" else _cs_word
    if 1 <= n <= 20 or (n % 10 == 0 and 20 < n <= 100):
        return word(n, case)
    if 20 < n < 100:
        return f"{word(n - n % 10, case)} {word(n % 10, case)}"
    return None


def _case_for(language: str, following: list[str], preceding: str | None) -> str:
    """The case the word after the ordinal (past joiners) asks for."""
    governing = next(
        (w for w in following if w.lower() not in _JOINERS and not w[0].isdigit()),
        "",
    )
    word = governing.lower()
    known = _KNOWN_NOUNS[language].get(word)
    if known:
        return known
    if language == "cs" and word in _CS_CASELESS:
        return _CS_PREPOSITION_CASE.get((preceding or "").lower(), N_NOM)
    if len(word) >= 3:
        for ending, case in _ADJECTIVE_ENDINGS[language]:
            if word.endswith(ending):
                return case
        if word.endswith(_NEUTER_ENDINGS[language]):
            return N_NOM
    return M_NOM


def spell_ordinals(text: str, language: str) -> str:
    """Replace "N." ordinals in sk/cs ``text`` with declined words."""
    if language not in ("sk", "cs"):
        return text

    def replace(match: re.Match) -> str:
        if not match.group(2).islower():
            return match.group(0)  # "… v roku 1945. Kto …": a sentence end
        n = int(match.group(1))
        source = match.string  # the date-spelled text, not the original
        following = _WORD_RE.findall(source[match.end() : match.end() + 80])[:4]
        before = _WORD_RE.findall(source[max(0, match.start() - 40) : match.start()])
        case = _case_for(language, following, before[-1] if before else None)
        # Above 100: the cardinal pass spells the digits; only the period goes.
        return ordinal_words(n, language, case) or match.group(1)

    def replace_date(match: re.Match) -> str:
        day, month = int(match.group(1)), int(match.group(2))
        if not (1 <= day <= 31 and 1 <= month <= 12):
            return match.group(0)
        month_word = _MONTHS_GENITIVE[language][month - 1]
        rest = match.string[match.end() :]
        tail = " " if rest[:1].isdigit() else ""
        return f"{ordinal_words(day, language, GEN)} {month_word}{tail}"

    return _ORDINAL_RE.sub(replace, _NUMERIC_DATE_RE.sub(replace_date, text))
