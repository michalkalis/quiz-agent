"""Spelled-out answers joined into one word (#208.2).

TF test 2026-10-16: when the recogniser kept mishearing "Váh", the player
spelled it ("V A H") and the transcript came back as separate letters, which
the sound-alike tiers and the judge cannot match. Deterministic and cheap, so
it runs on every open-answer transcript before the intent parser.

A run of at least three letters is joined into one token. A letter is a single
letter ("V", "Í."), a hyphen/dot-separated chain inside one token ("P-A-R-Í-Ž",
"U.S.A."), or a sk/cs/en letter name ("pé", "dvojité vé", "bee"). Names are
compared diacritic-folded ("zet" and "žet" both count).

False-positive guards, because ordinary speech is full of one-letter words
("a", "v", "i") and words that sound like letter names ("je", Czech "té"):
English names that are everyday words ("see", "you", "are", "why") are not
letters at all, and a run must hold at least two *strong* letters — an
uppercase single letter (how the recogniser writes spelling), a chain, or a
name that is no ordinary word. So "a je v Paríži" and Czech "a v té době" stay
as they are, while "V A H" and "pé á er í žet" are joined. When the word itself
is said right next to its spelling ("V A H váh"), the word is kept and the
spelling dropped.
"""

from __future__ import annotations

import re
import unicodedata

MIN_RUN = 3
MIN_STRONG = 2

# Exact (lowercased) letter name -> the letter it spells.
_NAMES = {
    # Slovak / Czech
    "á": "a",
    "bé": "b",
    "cé": "c",
    "čé": "č",
    "dé": "d",
    "ďé": "ď",
    "é": "e",
    "ef": "f",
    "gé": "g",
    "há": "h",
    "chá": "ch",
    "í": "i",
    "jé": "j",
    "ká": "k",
    "el": "l",
    "eľ": "ľ",
    "em": "m",
    "en": "n",
    "eň": "ň",
    "ó": "o",
    "pé": "p",
    "kú": "q",
    "kvé": "q",
    "er": "r",
    "es": "s",
    "eš": "š",
    "té": "t",
    "ťé": "ť",
    "ú": "u",
    "vé": "v",
    "iks": "x",
    "ypsilon": "y",
    "ipsilon": "y",
    "zet": "z",
    "žet": "ž",
    # English (homophones of everyday words deliberately absent)
    "bee": "b",
    "cee": "c",
    "dee": "d",
    "eff": "f",
    "gee": "g",
    "aitch": "h",
    "jay": "j",
    "kay": "k",
    "ell": "l",
    "pee": "p",
    "cue": "q",
    "ar": "r",
    "ess": "s",
    "tee": "t",
    "vee": "v",
    "ex": "x",
    "wye": "y",
    "zee": "z",
    "zed": "z",
}
# Two-word names: first word -> (second word, letter).
_PAIRS = {"dvojité": ("vé", "w"), "dvojitý": ("vé", "w"), "double": ("u", "w")}

_PUNCT = ".,;:!?\"'()"
# Names (as written, lowercased) that are also ordinary sk/cs/en words or
# hesitations: they can extend a run but never make one. Accented forms such
# as "jé" or "há" are plain letter names, except Czech "té" ("that").
_WEAK_NAMES = {"je", "te", "té", "de", "ha", "ex", "gee", "em", "er", "el", "en", "es"}


def _fold(text: str) -> str:
    decomposed = unicodedata.normalize("NFKD", text.lower())
    return "".join(c for c in decomposed if not unicodedata.combining(c))


_FOLDED_NAMES = {_fold(k): _fold(v) for k, v in _NAMES.items()}
_FOLDED_PAIRS = {_fold(k): (_fold(w), letter) for k, (w, letter) in _PAIRS.items()}


def _core(token: str) -> str:
    return token.strip(_PUNCT)


def _letters_of(token: str) -> tuple[list[str], int] | None:
    """(letters, how many are strong) one token spells, or None if not spelling."""
    core = _core(token)
    if len(core) == 1 and core.isalpha():
        return [core], int(core.isupper())
    lowered, folded = core.lower(), _fold(core)
    if lowered in _NAMES:
        return [_NAMES[lowered]], int(lowered not in _WEAK_NAMES)
    if folded in _FOLDED_NAMES:
        return [_FOLDED_NAMES[folded]], int(lowered not in _WEAK_NAMES)
    parts = [p for p in re.split(r"[-.]", core) if p]
    if len(parts) >= MIN_RUN and all(len(p) == 1 and p.isalpha() for p in parts):
        return parts, len(parts)
    return None


def _pair_letter(first: str, second: str) -> str | None:
    pair = _FOLDED_PAIRS.get(_fold(_core(first)))
    if pair and _fold(_core(second)) == pair[0]:
        return pair[1]
    return None


def collapse_spelling(text: str) -> str:
    """Join spelled-out letters into one word; any other text is returned as is."""
    tokens = text.split()
    out: list[str] = []
    i = 0
    changed = False
    while i < len(tokens):
        letters: list[str] = []
        strong = 0
        j = i
        while j < len(tokens):
            if j + 1 < len(tokens) and (pair := _pair_letter(tokens[j], tokens[j + 1])):
                letters.append(pair)
                strong += 1
                j += 2
                continue
            spelled = _letters_of(tokens[j])
            if spelled is None:
                break
            letters.extend(spelled[0])
            strong += spelled[1]
            j += 1
        if len(letters) < MIN_RUN or strong < MIN_STRONG:
            out.append(tokens[i])
            i += 1
            continue
        word = "".join(letters)
        last = tokens[j - 1]
        tail = last[len(last.rstrip(_PUNCT)) :]
        changed = True
        if j < len(tokens) and _fold(_core(tokens[j])) == _fold(word):
            # "V A H váh": the player spelled it, then said it — keep the word.
            i = j
            continue
        if out and _fold(_core(out[-1])) == _fold(word):
            # "Váh, V A H": the word came first.
            i = j
            continue
        out.append(word + tail)
        i = j
    return " ".join(out) if changed else text
