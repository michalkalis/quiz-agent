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

from .ordinals import spell_ordinals

logger = logging.getLogger(__name__)

# Languages whose TTS input gets digit→words normalization. English TTS
# handles digits natively; every other supported quiz language that num2words
# covers can be added here.
_PERCENT_WORD = {
    "sk": "percent",
    "cs": "procent",
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
}
_AMPERSAND_RE = re.compile(r"\s&\s")
_AND_WORD = {"sk": "a", "cs": "a"}


def _spell_symbols(text: str, language: str) -> str:
    for symbol, word in _SYMBOL_WORDS[language].items():
        text = re.sub(rf"\s*{re.escape(symbol)}\s*", f" {word} ", text).strip()
    # Only a free-standing "&" ("Tom & Jerry"); "AT&T" stays a name.
    return _AMPERSAND_RE.sub(f" {_AND_WORD[language]} ", text)


def normalize_numbers_for_tts(text: str, language: str) -> str:
    """Replace digit runs (and a few symbols) with spelled-out words for `language`.

    Fail-safe: any error (unsupported language, unparsable token) leaves the
    affected token — or the whole text — unchanged.
    """
    if language not in _PERCENT_WORD:
        return text
    text = _spell_symbols(text, language)
    if not any(ch.isdigit() for ch in text):
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
            return num2words(value, lang=language)
        except NotImplementedError:
            return token

    try:
        # Ordinals first (#200): "19. storočí" must become one declined word,
        # not the cardinal plus a sentence-end period ("devätnásť. storočí").
        text = spell_ordinals(text, language)
        text = _DECIMAL_COMMA_RE.sub(
            lambda m: _spell_decimal_comma(m, language, num2words), text
        )
        result = _NUMBER_RE.sub(spell, text)
        return result.replace("%", " " + _PERCENT_WORD[language]).replace("  ", " ")
    except Exception:
        logger.exception("TTS number normalization failed — using original text")
        return text
