"""The one place that knows which quiz languages exist and which are servable.

Issue #168 — batch translation pipeline SK/CS, DD14/DD15. Two different lists,
deliberately kept apart:

* ``QUIZ_LANGUAGES`` — every code the *data model* understands. It never
  shrinks: stored sessions, packs and translation rows keep referring to these
  codes long after a language stops being offered, so this is the vocabulary,
  not the menu.
* ``servable_quiz_languages()`` / ``pack_order_languages()`` — the menu, read
  from the environment. Languages come back one at a time as approved corpora
  land, so re-enabling one must be an env flip on a running deploy, not a code
  change and a build.

Both services import this module so quiz-agent (session language) and
quiz-pack-api (pack order language) can never drift into accepting different
sets — the drift that DD14 exists to prevent.
"""

from __future__ import annotations

import logging
import os

logger = logging.getLogger(__name__)

# The ten codes every build shipped before the gate existed (#138). Installed
# builds still offer them all, so a request in one that is not listed is
# accepted with a warning rather than rejected (#168).
LEGACY_QUIZ_LANGUAGES: tuple[str, ...] = (
    "en",
    "sk",
    "cs",
    "de",
    "fr",
    "es",
    "it",
    "pl",
    "hu",
    "ro",
)

# Every code the app has ever offered. Additive only.
# #231: "uk" is known to the data model but, unlike the legacy codes, no build
# offers it, so it is dark until SERVABLE_QUIZ_LANGUAGES / PACK_ORDER_LANGUAGES
# list it (defaults below stay en,sk,cs).
QUIZ_LANGUAGES: tuple[str, ...] = (*LEGACY_QUIZ_LANGUAGES, "uk")

# Languages served ONLY from rows written natively in them (plus stored,
# approved translations). Every other non-English language may fall back to an
# English row translated live by an LLM at serve time; that is acceptable for
# sk/cs, which have verified stored translations. Ukrainian has none (the
# translation tool supports only sk and cs), so a live translation would reach
# the player with no Russian-language check, no Ukrainian topic policy and no
# human approval. A language leaves this set when the translation tool supports it.
NATIVE_ONLY_LANGUAGES: frozenset[str] = frozenset({"uk"})


def is_dark_language(code: str, listed: tuple[str, ...]) -> bool:
    """True for a language no installed build offers that is not listed yet.

    Such a request must be refused (422), unlike a legacy code, which is only
    warned about. Once the env list includes the code this is False.
    """
    return code in QUIZ_LANGUAGES and code not in LEGACY_QUIZ_LANGUAGES and code not in listed


# DD14: quiz sessions default to the three languages with an approved corpus.
_DEFAULT_SERVABLE_QUIZ = "en,sk,cs"
# DD15 → #192: packs are generated natively in the ordered language (the
# generation prompt carries an output-language section for sk/cs), so the
# orderable set matches the servable one.
_DEFAULT_PACK_ORDER = "en,sk,cs"


def _parse(env_var: str, default: str) -> tuple[str, ...]:
    """Comma-separated env list → known codes, order preserved, deduped.

    Unknown codes are dropped with a WARNING rather than raising: this runs at
    request time in two services, and a fat-fingered env var must not turn into
    a 500 on every call. An env value that leaves nothing usable falls back to
    the default so a typo can never make the app offer *no* languages at all.
    """
    raw = os.getenv(env_var)
    if raw is None or not raw.strip():
        raw = default

    seen: list[str] = []
    for chunk in raw.split(","):
        code = chunk.strip().lower()
        if not code or code in seen:
            continue
        if code not in QUIZ_LANGUAGES:
            logger.warning(
                "%s lists unknown language code %r; ignoring (known codes: %s)",
                env_var,
                code,
                ",".join(QUIZ_LANGUAGES),
            )
            continue
        seen.append(code)

    if not seen:
        logger.warning(
            "%s=%r yielded no known language codes; falling back to %r",
            env_var,
            raw,
            default,
        )
        return _parse_default(default)
    return tuple(seen)


def _parse_default(default: str) -> tuple[str, ...]:
    return tuple(
        code
        for code in (chunk.strip().lower() for chunk in default.split(","))
        if code in QUIZ_LANGUAGES
    )


def servable_quiz_languages() -> tuple[str, ...]:
    """Quiz languages currently offered to players (``SERVABLE_QUIZ_LANGUAGES``).

    Read per call, not cached at import: flipping the env var on a deploy must
    change the answer without a code change (DD14 acceptance).
    """
    return _parse("SERVABLE_QUIZ_LANGUAGES", _DEFAULT_SERVABLE_QUIZ)


def pack_order_languages() -> tuple[str, ...]:
    """Languages a custom pack may be ordered in (``PACK_ORDER_LANGUAGES``)."""
    return _parse("PACK_ORDER_LANGUAGES", _DEFAULT_PACK_ORDER)
