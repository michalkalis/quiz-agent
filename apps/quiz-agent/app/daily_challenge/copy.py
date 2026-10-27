"""Crowd lines in sk/cs/en (#205). Short, no filler, no dashes (founder decision 3).

Display lines go on the result strip, the round end and the Home card; spoken
lines are appended to the feedback utterance, so they spell "percent" out and
leave digits to the TTS number normalizer. Any other language falls back to
English, like ``feedback_messages``.
"""

from __future__ import annotations

from typing import Optional

from .rules import Crowd, CrowdKind, Standing

NBSP = " "


def _lang(language: str) -> str:
    return language if language in ("sk", "cs") else "en"


def _count_verb(language: str, k: int) -> str:
    """Past "knew" agreeing with a number of people ("Vedel 1", "Vedeli 2", "Vedelo 5")."""
    if language == "sk":
        return "Vedel" if k == 1 else "Vedeli" if 2 <= k <= 4 else "Vedelo"
    return "Věděl" if k == 1 else "Věděli" if 2 <= k <= 4 else "Vědělo"


def _percent_verb(language: str, p: int) -> str:
    """Past "knew" agreeing with "percento / percentá / percent"."""
    if language == "sk":
        return "Vedeli" if 2 <= p <= 4 else "Vedelo"
    return "Věděla" if 2 <= p <= 4 else "Vědělo"


def _percent_word(language: str, p: int) -> str:
    if language == "sk":
        return "percento" if p == 1 else "percentá" if 2 <= p <= 4 else "percent"
    if language == "cs":
        return "procento" if p == 1 else "procenta" if 2 <= p <= 4 else "procent"
    return "percent"


def cs_from(n: int) -> str:
    """Czech "z" or "ze" before a number, by how its genitive is spoken
    ("ze dvou", "ze tří", "z pěti", "ze sedmi", "ze dvaceti", "ze sta")."""
    if n >= 1000:
        return cs_from(n // 1000) if n // 1000 >= 2 else "z"
    if n >= 100:
        return "ze" if n // 100 in (1, 2, 3, 4, 6, 7) else "z"
    if n >= 20:
        return "ze" if n // 10 in (2, 3, 4, 6, 7) else "z"
    return "ze" if n in (2, 3, 4, 6, 7, 12, 13, 14, 16, 17) else "z"


def sk_from(n: int) -> str:
    """Slovak "z" or "zo" before a number ("zo štyroch", "zo siedmich",
    "zo sto", but "z troch", "z piatich")."""
    if n >= 1000:
        return sk_from(n // 1000) if n // 1000 >= 2 else "z"
    if n >= 100:
        return "zo" if n // 100 in (1, 4, 6, 7) else "z"
    if n >= 20:
        return "zo" if n // 10 in (4, 6, 7) else "z"
    return "zo" if n in (4, 6, 7, 14, 16, 17) else "z"


def _of(language: str, n: int) -> str:
    return cs_from(n) if language == "cs" else sk_from(n)


FIRST = {
    "sk": "Dnes nikto nehral pred tebou.",
    "cs": "Dnes nikdo nehrál před tebou.",
    "en": "Nobody played before you today.",
}


def strip_text(crowd: Crowd, language: str) -> str:
    """The result-screen strip: counts below 20 others, a percentage from 20,
    "first today" with nobody else yet."""
    lang = _lang(language)
    if crowd.others == 0:
        return FIRST[lang]
    if crowd.knew == 0:
        return rare_text(crowd, language)
    k, n, p = crowd.knew, crowd.others, crowd.percent
    if lang == "en":
        return f"{p}% knew." if crowd.uses_percent else f"{k} of {n} knew."
    if crowd.uses_percent:
        return f"{_percent_verb(lang, p)} {p}{NBSP}%."
    return f"{_count_verb(lang, k)} {k} {_of(lang, n)} {n}."


def rare_text(crowd: Crowd, language: str) -> str:
    """A rare hit on screen ("Vedeli to len 2 z 9."). Needs others > 0."""
    lang = _lang(language)
    k, n, p = crowd.knew, crowd.others, crowd.percent
    if k == 0:
        return {
            "sk": "Nikto iný to nevedel.",
            "cs": "Nikdo jiný to nevěděl.",
            "en": "Nobody else knew that.",
        }[lang]
    if lang == "en":
        return (
            f"Only {p}% knew that."
            if crowd.uses_percent
            else f"Only {k} of {n} knew that."
        )
    only = "len" if lang == "sk" else "jen"
    if crowd.uses_percent:
        return f"{_percent_verb(lang, p)} to {only} {p}{NBSP}%."
    return f"{_count_verb(lang, k)} to {only} {k} {_of(lang, n)} {n}."


_HARD = {
    "sk": ["Väčšina to nevie.", "Na tomto padá väčšina.", "Toto väčšina nedá."],
    "cs": ["Většina to neví.", "Na tomhle padá většina.", "Tohle většina nedá."],
    "en": [
        "Most people miss this one.",
        "This one trips up most players.",
        "Most players get this wrong.",
    ],
}


def spoken_line(kind: CrowdKind, crowd: Crowd, language: str, variant: int) -> str:
    """One short sentence for the host, rare or hard only. ``variant`` (the
    number of lines already spoken) rotates the wording."""
    lang = _lang(language)
    if kind == "hard":
        options = _HARD[lang]
        return options[variant % len(options)]
    k, n, p = crowd.knew, crowd.others, crowd.percent
    if k == 0:
        return rare_text(crowd, language)
    alt = variant % 2 == 1
    if lang == "en":
        amount = f"{p} percent" if crowd.uses_percent else f"{k} of {n}"
        return f"Just {amount} got that." if alt else f"Only {amount} knew that."
    only = "Len" if lang == "sk" else "Jen"
    if crowd.uses_percent:
        verb, amount = _percent_verb(lang, p), f"{p} {_percent_word(lang, p)}"
    else:
        verb, amount = _count_verb(lang, k), f"{k} {_of(lang, n)} {n}"
    if alt:
        return f"{only} {amount} to {verb.lower()}."
    return f"{verb} to {only.lower()} {amount}."


def best_hit_text(crowd: Crowd, rare: bool, language: str) -> Optional[str]:
    if crowd.others == 0:
        return None
    return rare_text(crowd, language) if rare else strip_text(crowd, language)


def rank_text(standing: Standing, language: str) -> Optional[str]:
    """Only in the top half (never "worse than…")."""
    if not standing.top_half:
        return None
    lang = _lang(language)
    n, b = standing.others, standing.beaten
    if standing.beat_everyone:
        return {
            "sk": f"Najlepšie skóre {sk_from(n + 1)} {n + 1} hráčov.",
            "cs": f"Nejlepší skóre {cs_from(n + 1)} {n + 1} hráčů.",
            "en": f"Best score of {n + 1} players.",
        }[lang]
    if n >= 20:
        p = round(100 * b / n)
        return {
            "sk": f"Lepšie skóre ako {p}{NBSP}% {sk_from(n)} {n} hráčov.",
            "cs": f"Lepší než {p}{NBSP}% {cs_from(n)} {n} hráčů.",
            "en": f"Better than {p}% of {n} players.",
        }[lang]
    return {
        "sk": f"Lepšie skóre ako {b} {sk_from(n)} {n} hráčov.",
        "cs": f"Lepší než {b} {cs_from(n)} {n} hráčů.",
        "en": f"Better than {b} of {n} players.",
    }[lang]


def comparison_text(standing: Standing, language: str) -> Optional[str]:
    """Round end and Home card: first today, rank in the top half, otherwise
    "tough challenge" (nothing for a perfect score that did not out-rank)."""
    lang = _lang(language)
    if standing.others == 0:
        return FIRST[lang]
    rank = rank_text(standing, language)
    if rank:
        return rank
    if standing.score >= standing.total:
        return None
    return {"sk": "Ťažká výzva.", "cs": "Těžká výzva.", "en": "Tough challenge."}[lang]
