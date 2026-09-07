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

# Every code the app has ever offered (#138). Additive only.
QUIZ_LANGUAGES: tuple[str, ...] = (
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

# DD14: quiz sessions default to the three languages with an approved corpus.
_DEFAULT_SERVABLE_QUIZ = "en,sk,cs"
# DD15: packs are generated in English and merely stamped with the ordered
# code, so ordering a non-EN pack would silently deliver English. English only
# until pack generation is natively multi-language (follow-up issue).
_DEFAULT_PACK_ORDER = "en"


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
