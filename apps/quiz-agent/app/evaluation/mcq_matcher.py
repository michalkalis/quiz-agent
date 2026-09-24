"""Spoken multiple-choice answer → option key (#185 track G).

One source of truth for every client. Until #184 the iOS ``MCQTranscriptMatcher``
resolved "céčko" / "tretia" / "dva" before submitting; the batch voice path
(#184) uploads audio instead, so that matcher never ran and the server's
exact-match check graded every such answer "incorrect" (founder car test
2026-09-23: "C" was not understood). This module ports the iOS tiers and adds
what the car test and the founder's labelling decision need.

**Labels (founder decision 2026-09-24):** options are labelled ``1``–``4``;
``A``–``D`` only when the options themselves are numbers, so "tri" can never
mean both "option 3" and the answer "3". :func:`option_labels` derives that
deterministically from the options.

**Matching order** (every tier must identify exactly ONE option, else it falls
through; nothing found → ``None``, which the caller reports as *unmatched* —
the player is asked again, never marked wrong):

1. *Value* — the option text itself was said ("Paríž", "je to Paríž"), with
   number words bridged to digits for numeric options ("štyri" → "4").
2. *Tolerant value* — Slovak/Czech declension ("kocku" for "Kocka") and
   recogniser near-misses ("Carling" for "Curling"), for options ≥ 4 letters.
3. *Directive* — a label, letter, ordinal or colloquial form: "dva",
   "dvojka", "druhá", "druhou", "the second one", "béčko", "B". Accepted only
   when the whole utterance is directive-shaped (every word is a directive or
   filler): "Karol Štvrtý" is a name, not "the fourth option".

A negation the options do not contain ("nie Paríž", "not B") never matches:
guessing past it would grade the opposite of what the player said.
"""

from __future__ import annotations

import re
from typing import Mapping, Optional

from .voice_match import fold, similarity

_LETTERS = "abcdefgh"
_FUZZY_THRESHOLD = 0.85
_LAST = -1  # sentinel position: "the last one"

# ── Vocabulary (folded: lowercase, no diacritics) — sk / cs / en ─────────────
# fmt: off
# Cardinal number words. Positional labels in the numbers scheme; in the letters
# scheme they can only name a numeric option's VALUE (bridged to digits).
_CARDINALS = {
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    "jeden": 1, "jedna": 1, "jedno": 1, "jednu": 1,
    "dva": 2, "dve": 2, "dvoch": 2, "dvou": 2,
    "tri": 3, "troch": 3, "trech": 3,
    "styri": 4, "ctyri": 4,
    "sest": 6, "sedem": 7, "sedm": 7,
    "osem": 8, "osm": 8, "devat": 9, "devet": 9, "desat": 10, "deset": 10,
}  # päť/pět ("pat"/"pet") left out: as plain words they are names and pets
# Colloquial number nouns ("dvojka", "trojku", "čtyřkou"): stem → number.
_NUMBER_NOUN_STEMS = {
    "jednotk": 1, "jednick": 1, "dvojk": 2, "trojk": 3, "stvork": 4, "ctyrk": 4,
}
_NUMBER_NOUN_ENDINGS = ("a", "u", "ou", "y", "e", "ach", "ami")
# Ordinals (positional in both schemes): stem → position, declined endings.
_ORDINAL_STEMS = {
    "prv": 1, "prvn": 1, "druh": 2, "tret": 3, "stvrt": 4, "ctvrt": 4,
    "posledn": _LAST,
}
_ORDINAL_ENDINGS = (
    "a", "y", "e", "u", "i", "o", "ou", "ej", "eho", "om", "ym", "im",
    "ia", "ie", "iu", "ieho", "iho", "imu", "emu", "ymu",
)
_EN_ORDINALS = {
    "first": 1, "second": 2, "third": 3, "fourth": 4, "last": _LAST,
    "1st": 1, "2nd": 2, "3rd": 3, "4th": 4,
}
# Letter nouns: sk/cs "áčko".."déčko", declined. Unambiguous anywhere.
_LETTER_NOUN_STEMS = {"ack": "a", "beck": "b", "ceck": "c", "deck": "d"}
_LETTER_NOUN_ENDINGS = ("o", "a", "u", "om", "e")
# Letters as spoken single syllables: "C", sk/cs "bé"/"cé"/"dé", en "bee"/"see".
# Too common as words (sk "a" = "and", en "be"/"see") to trust anywhere but as
# the ONE thing said ("C", "je to cé", "option B").
_WEAK_LETTER_WORDS = {
    "be": "b", "ce": "c", "de": "d", "bee": "b", "see": "c", "sea": "c", "dee": "d",
}
# English verbs that sound like letters: dropped when another label is said
# ("it could be C", "let me see, B").
_LETTER_LOOKALIKE_VERBS = frozenset({"be", "see"})
_NEGATIONS = frozenset({"nie", "ne", "not", "nope"})
# Words that carry no choice ("je to…", "the answer is…", "myslím, že…").
_FILLERS = frozenset(
    """
    je to ta ten tu te toto tato tuto teda tak takze no nuz asi hmm hm ehm em
    moznost moznosti moznostou odpoved odpovede odpovedi odpoved cislo cisla
    cislom pismeno pismena pismenko myslim myslime si ze by bude bola bol byt
    urcite podla mna mne mi ja som jsem volim vyberam vybiram vyberem beriem
    beru davam dam hovorim rikam reknu poviem odpovedam odpovidam prosim ok
    okej dobre hej ano jasne samozrejme vlastne nakoniec finalne konecne moja
    moje muj spravna spravne spravny ktora ktory ktere v s z k o u na vo zo ku
    the it its is i think guess say said answer option number letter choice
    my final go with pick choose will could would maybe probably um uh er
    okay yes yeah please that this im let me
    """.split()
)


# fmt: on


def sorted_option_keys(options: Mapping[str, str]) -> list[str]:
    """Display order everywhere: iOS ``sortedAnswerOptions`` and question TTS
    both sort by key, so position N is the N-th key in this order."""
    return sorted(options)


def _is_number_word(token: str) -> bool:
    return token in _CARDINALS


def _is_numeric_option(value: str) -> bool:
    folded = fold(value)
    if any(ch.isdigit() for ch in folded):
        return True
    tokens = folded.split()
    return bool(tokens) and all(_is_number_word(t) for t in tokens)


def label_scheme(options: Mapping[str, str]) -> str:
    """``"numbers"`` (1–4) unless any option is itself a number → ``"letters"``."""
    if any(_is_numeric_option(str(v)) for v in options.values()):
        return "letters"
    return "numbers"


def option_labels(options: Mapping[str, str]) -> dict[str, str]:
    """Key → the label a client shows and speaks for it ("1".."4" / "A".."D")."""
    keys = sorted_option_keys(options)
    if label_scheme(options) == "letters":
        return {k: _LETTERS[i].upper() for i, k in enumerate(keys)}
    return {k: str(i + 1) for i, k in enumerate(keys)}


# Words a recogniser should expect for a label, per session language (#185 G
# keyterms). English letters are left out: biasing a recogniser toward a bare
# "C" invents letters out of road noise.
_LABEL_WORDS = {
    "sk": {
        "1": "jedna",
        "2": "dva",
        "3": "tri",
        "4": "štyri",
        "A": "áčko",
        "B": "béčko",
        "C": "céčko",
        "D": "déčko",
    },
    "cs": {
        "1": "jedna",
        "2": "dva",
        "3": "tři",
        "4": "čtyři",
        "A": "áčko",
        "B": "béčko",
        "C": "céčko",
        "D": "déčko",
    },
    "en": {"1": "one", "2": "two", "3": "three", "4": "four"},
}


def label_keyterms(labels: Mapping[str, str], language: Optional[str]) -> list[str]:
    words = _LABEL_WORDS.get((language or "").lower(), {})
    return [words[label] for label in labels.values() if label in words]


def spoken_label(label: str, language: Optional[str]) -> str:
    """How question audio reads a label (founder 2026-09-24): numbers in the
    counting form ("Jedna", "Dva", "Tri"/"Tři", "Štyri"/"Čtyři", "One"…),
    letters as letters. A label with no word in this language stays as is."""
    if not label.isdigit():
        return label
    word = _LABEL_WORDS.get((language or "").lower(), {}).get(label)
    return word.capitalize() if word else label


# ── Matching ─────────────────────────────────────────────────────────────────


def _declined(token: str, stems: Mapping[str, object], endings) -> Optional[object]:
    for stem, value in stems.items():
        if token.startswith(stem) and token[len(stem) :] in endings:
            return value
    return None


def _spoken_number(token: str) -> Optional[int]:
    """A cardinal, digit or number noun → its number (not an ordinal)."""
    if token.isdigit():
        return int(token)
    if token in _CARDINALS:
        return _CARDINALS[token]
    value = _declined(token, _NUMBER_NOUN_STEMS, _NUMBER_NOUN_ENDINGS)
    return value if isinstance(value, int) else None


def _ordinal(token: str) -> Optional[int]:
    if token in _EN_ORDINALS:
        return _EN_ORDINALS[token]
    value = _declined(token, _ORDINAL_STEMS, _ORDINAL_ENDINGS)
    return value if isinstance(value, int) else None


def _letter_noun(token: str) -> Optional[str]:
    value = _declined(token, _LETTER_NOUN_STEMS, _LETTER_NOUN_ENDINGS)
    return value if isinstance(value, str) else None


def _weak_letter(token: str) -> Optional[str]:
    if len(token) == 1 and token.isalpha():
        return token
    return _WEAK_LETTER_WORDS.get(token)


def _key_for_position(position: int, keys: list[str]) -> Optional[str]:
    if position == _LAST:
        return keys[-1]
    if 1 <= position <= len(keys):
        return keys[position - 1]
    return None


def _key_for_letter(letter: str, keys: list[str]) -> Optional[str]:
    # A key that IS the letter wins (today's iOS shows key.uppercased()).
    for key in keys:
        if fold(key) == letter:
            return key
    return (
        _key_for_position(_LETTERS.index(letter) + 1, keys)
        if letter in _LETTERS
        else None
    )


def _unique(found: set[str]) -> Optional[str]:
    return next(iter(found)) if len(found) == 1 else None


def _value_match(
    spoken: str, tokens: list[str], options: Mapping[str, str]
) -> Optional[str]:
    padded = f" {spoken} "
    spoken_numbers = {n for n in (_spoken_number(t) for t in tokens) if n is not None}
    found: set[str] = set()
    for key, raw in options.items():
        value = fold(str(raw))
        if not value:
            continue
        if spoken == value or f" {value} " in padded:
            found.add(key)
        elif value.isdigit() and int(value) in spoken_numbers:
            found.add(key)
        elif _is_number_word(value) and _CARDINALS[value] in spoken_numbers:
            found.add(key)
    return _unique(found)


def _inflected(token: str, value: str) -> bool:
    """Declined or mis-heard form of a single-word option (iOS #171 Track I)."""
    if len(token) < 4:
        return False
    if similarity(token, value) >= _FUZZY_THRESHOLD:
        return True
    stem = 0
    for a, b in zip(token, value):
        if a != b:
            break
        stem += 1
    shorter = min(len(token), len(value))
    return (
        stem >= 3
        and stem >= 0.6 * shorter
        and len(token) - stem <= 3
        and len(value) - stem <= 3
    )


def _tolerant_match(
    spoken: str, tokens: list[str], options: Mapping[str, str]
) -> Optional[str]:
    found: set[str] = set()
    for key, raw in options.items():
        value = fold(str(raw))
        if len(value) < 4:
            continue
        words = value.split()
        if len(words) > 1:
            if similarity(spoken, value) >= _FUZZY_THRESHOLD or all(
                any(t == w if len(w) < 4 else _inflected(t, w) for t in tokens)
                for w in words
            ):
                found.add(key)
        elif any(_inflected(t, value) for t in tokens):
            found.add(key)
    return _unique(found)


def _is_directive(token: str) -> bool:
    return (
        _ordinal(token) is not None
        or _spoken_number(token) is not None
        or _letter_noun(token) is not None
        or _weak_letter(token) is not None
    )


def _directive_match(tokens: list[str], keys: list[str], scheme: str) -> Optional[str]:
    content: list[str] = []
    for i, token in enumerate(tokens):
        # "the second one": after an ordinal, "one" is a pronoun, not option 1.
        if token == "one" and i > 0 and _ordinal(tokens[i - 1]) is not None:
            continue
        if token not in _FILLERS:
            content.append(token)
    others = [t for t in content if t not in _LETTER_LOOKALIKE_VERBS]
    if others and all(_is_directive(t) for t in others):
        content = others  # "it could be C": "be" is the verb here
    if not content:
        return None

    strong: set[str] = set()
    weak: set[str] = set()
    for token in content:
        ordinal = _ordinal(token)
        number = _spoken_number(token)
        letter = _letter_noun(token)
        if ordinal is not None:
            key = _key_for_position(ordinal, keys)
        elif number is not None:
            if scheme != "numbers":
                return None  # in the letters scheme a number names a value, not a slot
            key = _key_for_position(number, keys)
        elif letter is not None:
            key = _key_for_letter(letter, keys)
        elif (weak_letter := _weak_letter(token)) is not None:
            if _key_for_letter(weak_letter, keys) is None:
                return None
            weak.add(weak_letter)
            continue
        else:
            return None  # other content: not a directive-shaped utterance
        if key is None:
            return None  # a label this question does not have ("tretia" of two)
        strong.add(key)

    if strong:
        return _unique(strong)
    if len(weak) != 1:
        return None  # "b alebo c" names no single option
    return _key_for_letter(next(iter(weak)), keys)


# "I'd say B", "it's C": drop the contraction so its stray letter ("d", "s")
# is not read as an option letter.
_CONTRACTION = re.compile(r"(?i)\b(i|it|that|you|we|they|he|she)['’](d|s|ll|m|re|ve)\b")


def match_option(
    transcript: str, options: Optional[Mapping[str, str]]
) -> Optional[str]:
    """The key of the one option ``transcript`` names, or ``None`` (unmatched)."""
    if not options:
        return None
    spoken = fold(_CONTRACTION.sub(r"\1", transcript))
    if not spoken:
        return None
    tokens = spoken.split()

    option_words = {w for raw in options.values() for w in fold(str(raw)).split()}
    if any(t in _NEGATIONS and t not in option_words for t in tokens):
        return None

    for tier in (_value_match, _tolerant_match):
        key = tier(spoken, tokens, options)
        if key is not None:
            return key
    return _directive_match(tokens, sorted_option_keys(options), label_scheme(options))
