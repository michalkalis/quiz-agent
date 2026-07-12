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


def normalize_numbers_for_tts(text: str, language: str) -> str:
    """Replace digit runs with spelled-out words for `language`.

    Fail-safe: any error (unsupported language, unparsable token) leaves the
    affected token — or the whole text — unchanged.
    """
    if language not in _PERCENT_WORD or not any(ch.isdigit() for ch in text):
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
        result = _NUMBER_RE.sub(spell, text)
        return result.replace("%", " " + _PERCENT_WORD[language]).replace("  ", " ")
    except Exception:
        logger.exception("TTS number normalization failed — using original text")
        return text
