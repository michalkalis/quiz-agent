"""Resolve a spoken multiple-choice reference ("béčko", "dva", "A") to an option key.

Since the options are read aloud (``tts.question_speech``) the app effectively
tells a driver to answer with a letter — so the letter is what they say. iOS
resolves that on the streaming STT path only
(``Hangs/Utilities/MCQTranscriptMatcher.swift``); the batch Whisper path and the
answer-confirmation sheet both send the raw transcript to the backend, which
understood nothing but the exact option key or the exact option value. "Béčko"
therefore scored *incorrect* on those paths, and a bare "A" was short enough to
be swallowed as a skip. Resolving here makes every path score one utterance the
same way.

Ambiguity resolves to ``None``, the same rule the iOS matcher uses: an utterance
naming two options is handed back to the caller unresolved rather than guessed
into a scored wrong answer.
"""

import re
import unicodedata
from collections.abc import Mapping

from ..translation.feedback_messages import OPTION_LETTER_NAMES

_NON_ALPHANUMERIC = re.compile(r"[^a-z0-9]+")


def _normalize(text: str) -> str:
    """Lowercase, drop diacritics ("béčko" → "becko"), reduce the rest to spaces.

    Slovak diacritics and STT punctuation must not defeat the lookup tables, and
    the folding has to match what iOS does so both sides accept the same words.
    """
    folded = unicodedata.normalize("NFKD", text.lower())
    unaccented = "".join(ch for ch in folded if not unicodedata.combining(ch))
    return _NON_ALPHANUMERIC.sub(" ", unaccented).strip()


# The recognizer accepts exactly what the synthesizer speaks: OPTION_LETTER_NAMES
# is the same table ``build_question_speech_text`` reads the options with
# ("Áčko: Paris."), so a language added there is understood here for free and the
# two can never drift apart.
_LETTER_NAMES: dict[str, str] = {
    _normalize(name): key
    for names in OPTION_LETTER_NAMES.values()
    for key, name in names.items()
}
# Spoken shorthand used instead of the full letter-name ("bé" for "béčko") —
# the same short forms iOS accepts in MCQTranscriptMatcher.letterNames.
_LETTER_NAMES.update({"be": "b", "ce": "c", "de": "d"})

# Spoken position → 1-based option index. English + Slovak words, mirroring
# MCQTranscriptMatcher.numberWords, plus the bare digits Whisper emits for spoken
# numerals — the batch transcription path is exactly the one this module fixes.
_NUMBER_WORDS: dict[str, int] = {
    "1": 1,
    "one": 1,
    "first": 1,
    "jedna": 1,
    "jeden": 1,
    "prva": 1,
    "prvy": 1,
    "prve": 1,
    "2": 2,
    "two": 2,
    "second": 2,
    "dva": 2,
    "dve": 2,
    "druha": 2,
    "druhy": 2,
    "druhe": 2,
    "3": 3,
    "three": 3,
    "third": 3,
    "tri": 3,
    "tretia": 3,
    "treti": 3,
    "tretie": 3,
    "4": 4,
    "four": 4,
    "fourth": 4,
    "styri": 4,
    "stvrta": 4,
    "stvrty": 4,
    "stvrte": 4,
}


def resolve_spoken_option(utterance: str, options: Mapping[str, str]) -> str | None:
    """Return the key of the single option ``utterance`` names, else ``None``.

    Recognizes the bare key ("a", "A"), the spoken letter-name ("áčko", "bé"),
    and the 1-based position ("two", "dva", "3") against options ordered by key —
    the same A/B/C/D order they are displayed and read aloud in.

    ``None`` means "not resolved", which includes the ambiguous case: an
    utterance naming more than one option must be left to the caller, never
    guessed, because a wrong guess is scored against the driver.
    """
    if not utterance or not options:
        return None

    ordered_keys = sorted(options)
    keys_by_normalized = {_normalize(key): key for key in ordered_keys}

    tokens = _normalize(utterance).split()
    # A bare key and a position word are only a reference when they are the WHOLE
    # utterance. Both collide with ordinary speech: "a" is the Slovak conjunction
    # and an English article, and numerals are this corpus's most common option
    # VALUE — so "one hundred" against {a: 10, b: 100} would otherwise resolve to
    # option A and score the driver's correct answer as wrong. The letter-names
    # ("béčko", "bé") carry no such collision and still match anywhere.
    is_bare = len(tokens) == 1

    matched = set()
    for token in tokens:
        if is_bare and token in keys_by_normalized:
            matched.add(keys_by_normalized[token])

        letter = _LETTER_NAMES.get(token)
        if letter is not None and letter in keys_by_normalized:
            matched.add(keys_by_normalized[letter])

        position = _NUMBER_WORDS.get(token) if is_bare else None
        if position is not None and position <= len(ordered_keys):
            matched.add(ordered_keys[position - 1])

    return matched.pop() if len(matched) == 1 else None
