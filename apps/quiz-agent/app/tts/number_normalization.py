"""Spell digits out as target-language words before TTS synthesis.

Founder bug 2026-07-12: translated Slovak questions keep Arabic numerals
("V roku 1969…"), and OpenAI tts-1 has no locale lever — digits embedded in
Slovak text are frequently read with English pronunciation. tts-1 also
ignores the `instructions` param, so the only reliable fix is normalizing
the TTS *input text* itself (deterministic transform — no LLM on the hot
path). Applies to the synthesized text only; the displayed question keeps
its numerals.
"""

import logging
import re

from .ordinals import F_LOC, ordinal_words, spell_ordinals

logger = logging.getLogger(__name__)

# Languages whose TTS input gets digit→words normalization. English TTS
# handles digits natively; every other supported quiz language that num2words
# covers can be added here.
_PERCENT_WORD = {
    "sk": "percent",
    "cs": "procent",
    "uk": "відсотків",
}

# A run of digits possibly containing thousands/decimal separators
# ("24,000", "24 000", "3.14", "1969"). Space-joined groups must be exactly
# 3 digits so adjacent independent numbers ("1969 a 12") never merge.
_NUMBER_RE = re.compile(r"\d+(?:[,.]\d+)*(?: \d{3})*")


def _parse_number(token: str) -> float | int | None:
    """Interpret separators: groups of exactly 3 digits → thousands,
    a final short group → decimal part. Returns None when ambiguous."""
    compact = token.replace(" ", "")
    if "," in compact and "." in compact:
        # The later separator is the decimal one; the other groups thousands.
        dec_sep = "," if compact.rfind(",") > compact.rfind(".") else "."
        thou_sep = "." if dec_sep == "," else ","
        compact = compact.replace(thou_sep, "").replace(dec_sep, ".")
        try:
            return float(compact)
        except ValueError:
            return None
    for sep in (",", "."):
        if sep in compact:
            head, *rest = compact.split(sep)
            if all(len(g) == 3 for g in rest):
                return int(head + "".join(rest))  # 24,000 / 1.000.000
            if len(rest) == 1:
                try:
                    return float(f"{head}.{rest[0]}")  # 3,14 / 3.14
                except ValueError:
                    return None
            return None
    try:
        return int(compact)
    except ValueError:
        return None


# Slovak and Czech write the decimal point as a comma and group thousands with
# a space (or a dot), so "30,126" is thirty point one two six, never thirty
# thousand (founder bug 2026-11-16: the euro rate "30,126 korún" was read as
# 30 126). Every sk/cs approved text with "d,ddd" was a decimal (7 of 7 on
# 2026-11-16: the rate and the marathon's 42,195 km).
_DECIMAL_COMMA_RE = re.compile(r"(?<![\d,.])(\d{1,3}(?:[ .]\d{3})*|\d+),(\d+)(?![\d,])")
# The integer before "celá/celé/celých" agrees with it in the feminine.
_FEMININE = {
    "sk": {1: "jedna", 2: "dve"},
    "cs": {1: "jedna", 2: "dvě"},
}
_ZERO = {"sk": "nula", "cs": "nula"}


def _uk_plural(n: int) -> int:
    """Ukrainian noun class: 0 = one (1, 21), 1 = few (2–4, 22–24), 2 = many
    (0, 5–20, 25–30; 11–14 are many)."""
    if n % 10 == 1 and n % 100 != 11:
        return 0
    if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14:
        return 1
    return 2


def _uk_cardinal(n: int, num2words) -> str:
    words = num2words(n, lang="uk")
    # num2words says "одна тисяча"; speech says "тисяча".
    return words[len("одна ") :] if words.startswith("одна тисяча") else words


def _uk_feminine(words: str) -> str:
    """ "двадцять один" → "двадцять одна", "два" → "дві" (last word only)."""
    head, _, last = words.rpartition(" ")
    last = {"один": "одна", "два": "дві"}.get(last, last)
    return f"{head} {last}".strip()


_UK_PLACE = {1: ("десята", "десятих"), 2: ("сота", "сотих"), 3: ("тисячна", "тисячних")}
_UK_PERCENT_FORMS = ("відсоток", "відсотки", "відсотків")
_UK_PERCENT_RE = re.compile(r"(?<![\d,.])(\d+)([,.]\d+)?\s?%")
# "3.5" is a decimal too; a dot before exactly three digits groups thousands.
_UK_DECIMAL_DOT_RE = re.compile(r"(?<![\d,.])(\d+)\.(\d{1,2}|\d{4,})(?![\d,]|\.\d)")
# …except a clock time after "о/об": "о 10.30" is "о десятій тридцять".
_UK_TIME_RE = re.compile(
    r"(?<![^\W\d_])(о|об)(\s+)([01]?\d|2[0-4])[.:]([0-5]\d)(?!\d|[.:,]\d)",
    re.IGNORECASE,
)


def _spell_time_uk(match: re.Match, num2words) -> str:
    """The hour as a feminine ordinal in the locative ("годині" left out), the
    minutes as a feminine count ("хвилин"): "о сьомій нуль п'ять", "об
    одинадцятій двадцять дві"; a full hour is just "о десятій"."""
    hour, minutes = int(match.group(3)), match.group(4)
    if hour == 0:
        return match.group(0)
    words = ordinal_words(hour, "uk", F_LOC)
    preposition = "об" if words.startswith("о") else "о"  # "об одинадцятій"
    if match.group(1)[0].isupper():
        preposition = preposition.capitalize()
    if minutes != "00":
        zero = "нуль " if minutes[0] == "0" else ""
        words += f" {zero}{_uk_feminine(_uk_cardinal(int(minutes), num2words))}"
    return f"{preposition}{match.group(2)}{words}"


# "7 з 10", "2 із 9": "out of" takes the genitive ("сім з десяти"); the first
# number stays as written.
_UK_OUT_OF_RE = re.compile(
    r"(?<![\d,.])(\d+\s+(?:з|із|зі)\s+)(\d{1,3}(?:[ \u00a0]\d{3})+|\d+)(?![\d]|[,.]\d)"
)
# fmt: off
_UK_GENITIVE_UNITS = (
    "нуля", "одного", "двох", "трьох", "чотирьох", "п'яти", "шести", "семи",
    "восьми", "дев'яти", "десяти", "одинадцяти", "дванадцяти", "тринадцяти",
    "чотирнадцяти", "п'ятнадцяти", "шістнадцяти", "сімнадцяти", "вісімнадцяти",
    "дев'ятнадцяти",
)
_UK_GENITIVE_TENS = {2: "двадцяти", 3: "тридцяти", 4: "сорока", 5: "п'ятдесяти",
                     6: "шістдесяти", 7: "сімдесяти", 8: "вісімдесяти", 9: "дев'яноста"}
_UK_GENITIVE_HUNDREDS = {1: "ста", 2: "двохсот", 3: "трьохсот", 4: "чотирьохсот",
                         5: "п'ятисот", 6: "шестисот", 7: "семисот", 8: "восьмисот",
                         9: "дев'ятисот"}
# fmt: on


def _uk_genitive(n: int) -> str | None:
    """A cardinal in the genitive ("десяти", "двадцяти одного", "двох тисяч");
    None from a million (left to the cardinal pass). num2words gets 200+ wrong
    ("двохста")."""
    if n >= 1_000_000:
        return None
    if n == 0:
        return _UK_GENITIVE_UNITS[0]
    words = []
    thousands, rest = divmod(n, 1000)
    if thousands == 1:
        words.append("тисячі")
    elif thousands:
        head = _uk_genitive(thousands)
        head = head[: -len("одного")] + "однієї" if head.endswith("одного") else head
        words += [head, "тисячі" if _uk_plural(thousands) == 0 else "тисяч"]
    hundreds, rest = divmod(rest, 100)
    if hundreds:
        words.append(_UK_GENITIVE_HUNDREDS[hundreds])
    if rest >= 20:
        words.append(_UK_GENITIVE_TENS[rest // 10])
        rest %= 10
    if rest:
        words.append(_UK_GENITIVE_UNITS[rest])
    return " ".join(words)


def _spell_out_of_uk(match: re.Match) -> str:
    words = _uk_genitive(int(re.sub(r"\D", "", match.group(2))))
    return f"{match.group(1)}{words}" if words else match.group(0)


def _spell_decimal_uk(match: re.Match, num2words) -> str:
    """ "3,14" → "три цілих чотирнадцять сотих", "3,05" → "три цілих п'ять
    сотих" (the place word follows the digit count). More than three decimals
    are read as one number."""
    whole = int(re.sub(r"[ .]", "", match.group(1)))
    digits = match.group(2).rstrip("0")
    if not digits:
        return _uk_cardinal(whole, num2words)
    # "ціла" is feminine, so is the whole part: "одна ціла", "дві цілих".
    head = _uk_feminine(_uk_cardinal(whole, num2words))
    head += " ціла" if _uk_plural(whole) == 0 else " цілих"
    value = int(digits)
    if len(digits) not in _UK_PLACE:
        return f"{head} {_uk_cardinal(value, num2words)}"
    one, other = _UK_PLACE[len(digits)]
    amount = _uk_feminine(_uk_cardinal(value, num2words))
    return f"{head} {amount} {one if _uk_plural(value) == 0 else other}"


def _spell_percent_uk(match: re.Match) -> str:
    """ "1%" → "1 відсоток", "3%" → "3 відсотки", "5%" → "5 відсотків",
    "3,5%" / "3.5%" → "3,5 відсотка" (the digits are spelled by the later pass)."""
    if match.group(2) and match.group(2).strip(",.0"):
        return f"{match.group(1)}{match.group(2)} відсотка"
    return f"{match.group(1)} {_UK_PERCENT_FORMS[_uk_plural(int(match.group(1)))]}"


def _whole_word(n: int) -> str:
    """celá (0, 1) / celé (2–4) / celých (5+), the same in sk and cs."""
    if n in (0, 1):
        return "celá"
    return "celé" if 2 <= n <= 4 else "celých"


def _spell_decimal_comma(match: re.Match, language: str, num2words) -> str:
    whole = int(re.sub(r"[ .]", "", match.group(1)))
    digits = match.group(2).rstrip("0")
    head = _FEMININE[language].get(whole) or num2words(whole, lang=language)
    if not digits:
        return head
    # Leading zeros are said ("3,05" → "tri celé nula päť"), the rest as one number.
    zeros = len(digits) - len(digits.lstrip("0"))
    tail = " ".join([_ZERO[language]] * zeros + [num2words(int(digits), lang=language)])
    return f"{head} {_whole_word(whole)} {tail}"


# Symbols the multilingual voice reads in English inside sk/cs text (founder
# 2026-10-25: "Symbolu @ v e-mailu" was read "at"). Spelled out like digits.
_SYMBOL_WORDS = {
    "sk": {"@": "zavináč"},
    "cs": {"@": "zavináč"},
    "uk": {"@": "равлик"},
}
_AMPERSAND_RE = re.compile(r"\s&\s")
_AND_WORD = {"sk": "a", "cs": "a", "uk": "і"}


# #231: a chemical symbol after "символ…/позначк…" is read the way Ukrainian
# school reads it (native speaker 2026-11-18: "Fe" came out as "еф і"; "ферум"
# makes the question obvious). Only after those words, so "C" or "O" elsewhere
# (a grade, a name) is never touched.
_UK_ELEMENT_READINGS = {
    "H": "аш", "He": "гелій", "Li": "літій", "C": "це", "N": "ен", "O": "о",
    "F": "фтор", "Ne": "неон", "Na": "натрій", "Mg": "магній", "Al": "алюміній",
    "Si": "силіцій", "P": "пе", "S": "ес", "Cl": "хлор", "Ar": "аргон",
    "K": "калій", "Ca": "кальцій", "Ti": "титан", "Cr": "хром", "Mn": "манган",
    "Fe": "ферум", "Co": "кобальт", "Ni": "нікол", "Cu": "купрум", "Zn": "цинк",
    "Br": "бром", "Ag": "аргентум", "Sn": "станум", "Sb": "стибій", "I": "йод",
    "W": "вольфрам", "Pt": "платина", "Au": "аурум", "Hg": "гідраргірум",
    "Pb": "плюмбум", "Ra": "радій", "U": "уран", "Pu": "плутоній",
}  # fmt: skip
_UK_ELEMENT_RE = re.compile(
    r"\b(символ\w*|позначк\w*|позначенн\w*)(\s+)([A-Z][a-z]?)(?![\w-])", re.IGNORECASE
)


def _spell_uk_elements(text: str) -> str:
    def read(match: re.Match) -> str:
        reading = _UK_ELEMENT_READINGS.get(match.group(3))
        if reading is None:
            return match.group(0)
        return f"{match.group(1)}{match.group(2)}{reading}"

    return _UK_ELEMENT_RE.sub(read, text)


def _spell_symbols(text: str, language: str) -> str:
    if language == "uk":
        text = _spell_uk_elements(text)
    for symbol, word in _SYMBOL_WORDS[language].items():
        text = re.sub(rf"\s*{re.escape(symbol)}\s*", f" {word} ", text).strip()
    # Only a free-standing "&" ("Tom & Jerry"); "AT&T" stays a name.
    return _AMPERSAND_RE.sub(f" {_AND_WORD[language]} ", text)


# #243.11 (founder TF 2026-11-22): names with digits are said the English way
# in every language ("50 Cent" came out as "päťdesiat Cent"). Left as written,
# the voice reads them as the name. Artists mostly; extend when one turns up.
_NAMES_WITH_DIGITS_RE = re.compile(
    r"(?<!\w)(?:50 Cent|Blink-182|Maroon 5|Sum 41|U2|UB40|deadmau5|East 17"
    r"|Level 42|S Club 7|Matchbox 20|Front 242|Jackson 5)(?!\w)"
)
# A code or model glued to its letters ("D1", "H0", "TR-808") kept the letters
# glued to the spelled number ("Djedna"); a space keeps both readable.
_LETTER_THEN_DIGIT_RE = re.compile(r"(?<=[^\W\d_])-?(?=\d)")
_PLACEHOLDER = "\ue000{}\ue001"
_PLACEHOLDER_RE = re.compile("\ue000([\ue100-\ue1ff])\ue001")


def _protect_names(text: str) -> tuple[str, list[str]]:
    names: list[str] = []

    def keep(match: re.Match) -> str:
        names.append(match.group(0))
        return _PLACEHOLDER.format(chr(0xE100 + len(names) - 1))

    return _NAMES_WITH_DIGITS_RE.sub(keep, text), names


def _restore_names(text: str, names: list[str]) -> str:
    return _PLACEHOLDER_RE.sub(lambda m: names[ord(m.group(1)) - 0xE100], text)


def normalize_numbers_for_tts(text: str, language: str) -> str:
    """Replace digit runs (and a few symbols) with spelled-out words for `language`.

    Fail-safe: any error (unsupported language, unparsable token) leaves the
    affected token — or the whole text — unchanged.
    """
    if language not in _PERCENT_WORD:
        return text
    original = text
    text, names = _protect_names(text)
    text = _LETTER_THEN_DIGIT_RE.sub(" ", text)
    return _restore_names(_normalize(text, language, original), names)


def _normalize(text: str, language: str, original: str) -> str:
    text = _spell_symbols(text, language)
    # uk also writes centuries in Roman numerals ("XX століття").
    if not any(ch.isdigit() for ch in text) and language != "uk":
        return text
    try:
        from num2words import num2words
    except ImportError:  # keeps the route alive if the dep is missing in an env
        logger.warning("num2words unavailable — TTS digits left as-is")
        return text

    def spell(match: re.Match) -> str:
        token = match.group(0)
        value = _parse_number(token)
        if value is None:
            return token
        try:
            if language == "uk" and isinstance(value, int):
                return _uk_cardinal(value, num2words)
            return num2words(value, lang=language)
        except NotImplementedError:
            return token

    try:
        if language == "uk":
            text = _UK_TIME_RE.sub(lambda m: _spell_time_uk(m, num2words), text)
        # Ordinals first (#200): "19. storočí" must become one declined word,
        # not the cardinal plus a sentence-end period ("devätnásť. storočí").
        text = spell_ordinals(text, language)
        if language == "uk":
            text = _UK_OUT_OF_RE.sub(_spell_out_of_uk, text)
            text = _UK_PERCENT_RE.sub(_spell_percent_uk, text)
            for decimal in (_DECIMAL_COMMA_RE, _UK_DECIMAL_DOT_RE):
                text = decimal.sub(lambda m: _spell_decimal_uk(m, num2words), text)
        else:
            text = _DECIMAL_COMMA_RE.sub(
                lambda m: _spell_decimal_comma(m, language, num2words), text
            )
        result = _NUMBER_RE.sub(spell, text)
        return result.replace("%", " " + _PERCENT_WORD[language]).replace("  ", " ")
    except Exception:
        logger.exception("TTS number normalization failed — using original text")
        return original
