"""The generation brief of the weekly fresh-entertainment run (#202 task 202.3).

``build_fresh_brief`` is a pure function: the #201 recipe's brief
(``docs/setup/fresh-entertainment-recipe.md`` § Brief) assembled the way
``docs/testing/runs/gettable-entertainment-2026-10-13/run_arm.sh`` builds arm
B — the same anchor, freshness and covered-answers parts, with the recipe's
focus and player paragraphs. The only inputs that change week to week are the
run date (freshness window), the seeds and the covered-facts lines, so a test
can pin every rule the founder's ratings depend on.
"""

from __future__ import annotations

from collections.abc import Sequence
from datetime import date, timedelta
from typing import TYPE_CHECKING

from app.corpus.covered import format_covered_block

if TYPE_CHECKING:
    from app.corpus.seed_filters import Seed

# ~10 weeks back from the run date (plan #202, Krok 3).
FRESH_WINDOW_DAYS = 70

_MONTHS = (
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
)

AUDIENCE = {
    "en": "adults anywhere in the world",
    "sk": "adults who live in Slovakia and play in Slovak",
    "cs": "adults who live in Czechia and play in Czech",
}

_FOCUS_EN = (
    "Every question is about global entertainment (film, TV and streaming, music, "
    "video games, viral pop-culture moments) that a casual fan anywhere in the "
    "world, not only in the US, would recognise."
)
_FOCUS_DOMESTIC = (
    "Most questions (about 7 in 10) are about the {nat} entertainment scene: "
    "{nat} celebrities, reality and TV shows, domestic hits, films and moments "
    "people in {country} talked about; the rest are world mega-hits well known in "
    "{country}. Do not ask about the {other} scene unless it is genuinely shared."
)
_SCENE = {"sk": ("Slovak", "Slovakia", "Czech"), "cs": ("Czech", "Czechia", "Slovak")}

PLAYER = (
    "Who must be able to answer: an ordinary adult who follows film, TV, music and "
    "celebrities only loosely. Pick a famous thing first, then a surprising angle. "
    "Both the subject and the detail you ask for must be something such a player "
    "could have caught, half-remembers or can reason their way to. Do not build "
    "questions around awards (who won, what was won) or around people behind the "
    "camera (directors, producers, puppeteers and other crew; famous singers and "
    "songwriters are fine), not even by asking it the other way round, and skip "
    "topics only US audiences or fans would know. If a seed is about these, skip "
    "it. Never ask an open question whose answer is a number: make it a "
    "multiple-choice question with 3 clearly different options, or pick another "
    "fact. At most 2 questions about the same person, band, film, series or "
    "game. No giveaways: the wording must not name or uniquely describe the answer."
)

ANCHOR = (
    "Every question must stay true forever: anchor it in time with a year or event "
    'name ("at the 2026 Emmys", "in her 2026 album"), never "currently", "this '
    'year", "last week", "the latest", and never ask about rankings or records '
    "that can change. Avoid CURRENT politics and CURRENT wars or armed conflicts "
    "(including countries involved in one); historical events and dark themes "
    "inside films, series or games are fine. No gossip. Mostly open questions "
    "answered in a few words; at most 3 multiple-choice."
)

_SEEDS_HEADER = (
    "Seed facts (names may lack diacritics - write them correctly; from web "
    "research on {today}, each with a source; verify independently, skip any you "
    "cannot confirm, and you may use other equally fresh facts):"
)


def freshness_window(today: date) -> str:
    """'between August and October 2026 (today is 2026-10-13)' (~10 weeks back)."""
    start = today - timedelta(days=FRESH_WINDOW_DAYS)
    end_month = f"{_MONTHS[today.month - 1]} {today.year}"
    if start.year == today.year:
        span = f"between {_MONTHS[start.month - 1]} and {end_month}"
    else:
        span = f"between {_MONTHS[start.month - 1]} {start.year} and {end_month}"
    return f"mostly {span} (today is {today.isoformat()})"


def focus(lang: str) -> str:
    if lang == "en":
        return _FOCUS_EN
    nat, country, other = _SCENE[lang]
    return _FOCUS_DOMESTIC.format(nat=nat, country=country, other=other)


def seed_line(seed: Seed) -> str:
    when = seed.event_date or "evergreen"
    fame = f"{seed.views} views" if seed.views else "fame unknown"
    angle = f" Angle: {seed.angle}" if seed.angle else ""
    return (
        f"- {when} | {seed.subject} ({fame}) | {seed.fact}{angle} | {seed.source_url}"
    )


def build_fresh_brief(
    lang: str, today: date, seeds: Sequence[Seed], covered: Sequence[str]
) -> str:
    """The ``--prompt`` text for one language's fresh-entertainment order."""
    fresh = (
        "Freshness: most questions are about things that happened or came out "
        f"recently, {freshness_window(today)}; the rest may be surprising facts "
        "about mega-famous films, songs, shows or games."
    )
    head = (
        f"FRESH entertainment questions for {AUDIENCE[lang]}. {focus(lang)} "
        f"{PLAYER} {fresh} {ANCHOR} {_SEEDS_HEADER.format(today=today.isoformat())}"
    )
    seed_block = "\n".join(seed_line(s) for s in seeds)
    return f"{head}\n{seed_block}\n\n{format_covered_block(list(covered))}"
