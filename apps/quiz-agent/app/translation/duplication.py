"""Deterministic guard against glued / duplicated words in translations (#171 Track G).

A live Slovak session served "Westminsterského palácapalác" — the model glued a
word to a truncated repeat of itself. The validators only checked emptiness and
length, so the artifact passed and was written to the durable cache, which has no
TTL: the same defect was then read back on every request.

The detector is intentionally dumb (no LLM, no dictionary): two shapes cover the
whole failure class, and anything it flags is retried by the normal validation
retry loop before the caller falls back to English.
"""

from itertools import pairwise

# Characters that can wrap a token in quiz text; stripped before comparing.
_TRIM = "\"'“”„‚‘’«»()[]{}.,;:!?…-–—"

# The shortest half of a glued repeat we are willing to call a defect. Four keeps
# "mama", "haha", "blabla" and similar real words out of the net.
_MIN_HALF = 4

# Reduplication that is real language, not an artifact. Deliberately tiny and
# explicit — every entry is something a quiz can plausibly mention. Hyphenated
# names ("Baden-Baden") need no entry: they are not alphabetic tokens, so the
# glued-repeat rule skips them by construction.
_ALLOWED = frozenset(
    {
        # word-pair shape ("X X")
        "sing sing",
        "wagga wagga",
        "bora bora",
        "pago pago",
        "walla walla",
        "duran duran",
        "boutros boutros",
        "cha cha",
        "new new",  # New New York etc. — a name, never a stutter
        # single-token shape ("XX")
        "couscous",
        "beriberi",
    }
)


def _normalize(token: str) -> str:
    return token.strip(_TRIM).casefold()


def _is_glued_repeat(token: str) -> bool:
    """True when the token is its own doubling: X+X, or X plus X minus one trailing char.

    "palácapalác" = "paláca" + "palác" is the shape that shipped to production;
    the even case ("palácpalác") is the same defect without the truncation.
    """
    n = len(token)
    if n < 2 * _MIN_HALF - 1 or not token.isalpha() or token in _ALLOWED:
        return False
    if len(set(token)) == 1:
        # "aaaaaaaa" is a run of one letter, not a word glued to its repeat —
        # the two readings are indistinguishable, so it is not our defect.
        return False
    if n % 2 == 0:
        head = token[: n // 2]
        return len(head) >= _MIN_HALF and token[n // 2 :] == head
    head = token[: (n + 1) // 2]
    return len(head) >= _MIN_HALF and token[(n + 1) // 2 :] == head[:-1]


def find_duplicated_word(text: str) -> str | None:
    """Return the offending fragment, or None when the text looks clean.

    Two rules: an immediately repeated word ("paláca paláca") and a word glued to
    a repeat of itself ("palácapalác").
    """
    if not text:
        return None

    tokens = [_normalize(t) for t in text.split()]

    for previous, current in pairwise(tokens):
        if (
            current
            and current == previous
            and any(ch.isalpha() for ch in current)
            and f"{current} {current}" not in _ALLOWED
        ):
            return f"{current} {current}"

    for token in tokens:
        if _is_glued_repeat(token):
            return token

    return None
