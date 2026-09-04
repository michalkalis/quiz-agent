#!/usr/bin/env python3
"""Propose per-category quiz subtopics for the #170 coverage layer (task 170.1).

Why this exists
---------------
#170 (coverage-driven dedup) steers direct generation towards the least
covered ``(language, category, subtopic)`` cells, and no per-category
subtopic layer exists in the repo (``topic_pool.json`` is flat and
un-keyed). Locked decision 5: **the model proposes, the founder approves**
once, and the approved result becomes a static file
(``app/generation/subtopics.json``) that the runtime only reads. This script
is the *proposal* half of that hand-off: it writes ONLY the ``--out`` file,
never into ``app/generation/``, and enables nothing.

What a good subtopic is (founder, 2026-09-04)
---------------------------------------------
Subtopics are *soft steering hints* — they land in the direct prompt's
``**Preferred Topics:**`` line next to the category, they are not fences.
So each one must be a broad territory that can host dozens of distinct
questions, not a single entity or a narrow fact cluster. The inspiration
list below is the international slice of the "Kvíz, please!" theme bank
(``docs/testing/runs/podcast-kvizplease-2026-09-03/themes-160-episodes.md``,
Czech-national themes dropped) — angles real quiz hosts found fun.

Fail-loud contract
------------------
The proposal is never silently trimmed to a subset of the taxonomy: every
requested category must come back, under exactly its own id, with a
non-empty, de-duplicated list; a category the model invented, a missing
one, a duplicate, or a name longer than the ``questions.subtopic`` column
(``VARCHAR(64)``, D8) exits 1 and writes nothing.

Usage
-----
::

    cd apps/quiz-pack-api
    LLM_GATEWAY=session python scripts/propose_subtopics.py \
        --out ../../docs/testing/runs/170-coverage-steering/subtopics-proposal.json

``LLM_GATEWAY=session`` runs on the Claude Code subscription (#169, zero
marginal cost); any other gateway works but is paid. ``--categories``
overrides the default ``CATEGORIES`` taxonomy (comma-separated ids).
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
from collections.abc import Sequence

# Ensure `app.*` imports resolve when invoked as `python scripts/…` from the
# apps/quiz-pack-api/ working dir (same guard as scripts/generate_pack.py).
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_APP_DIR = os.path.dirname(_SCRIPT_DIR)
if _APP_DIR in sys.path:
    sys.path.remove(_APP_DIR)
sys.path.insert(0, _APP_DIR)

from app.generation.classification import CATEGORIES
from langchain_core.messages import HumanMessage, SystemMessage
from pydantic import BaseModel, Field
from quiz_shared.llm import factory as llm_factory

logger = logging.getLogger("propose_subtopics")

# ``questions.subtopic VARCHAR(64)`` (#170 D8) — a longer name could never be
# persisted, so it is rejected here rather than at the first steered batch.
MAX_SUBTOPIC_CHARS = 64
# Session B's loader test (A1) requires >= 10 per category; the prompt asks
# for 15–20. The upper bound only catches a runaway list.
MIN_SUBTOPICS = 10
MAX_SUBTOPICS = 30
DEFAULT_TARGET = "15-20"

# One-line brief per category id so the model knows what the id means.
# Covers both the generation taxonomy (``CATEGORIES``) and the app's
# interest taxonomy (``CATEGORY_TAXONOMY`` in quiz-agent) — see the
# taxonomy note in issue-170 (Session A hand-off).
CATEGORY_BRIEFS: dict[str, str] = {
    "general": (
        "Broad general knowledge for an adult international audience — "
        "science, history, geography, culture, language, everyday life; "
        "anything not owned by a themed category."
    ),
    "adults": (
        "Grown-up general knowledge: work and careers, money, law, "
        "relationships, wine and spirits, nightlife, adult pop culture. "
        "Nothing explicit."
    ),
    "kids": (
        "Questions children aged roughly 6–12 can answer and enjoy: animals, "
        "nature, cartoons, fairy tales, toys and games, school basics, "
        "the world around them."
    ),
    "wizarding-world": (
        "The Harry Potter / Fantastic Beasts universe: books, films, "
        "characters, places, creatures, magic, behind the scenes."
    ),
    "superheroes": (
        "Marvel, DC and other superhero comics, films and series: heroes, "
        "villains, origins, actors, teams, powers."
    ),
    "disney": (
        "Disney and Pixar: animated and live-action films, characters, "
        "songs, villains, parks, history of the studio."
    ),
    "football": (
        "Association football (soccer): clubs, players, managers, "
        "competitions, World Cups, records, rules, history."
    ),
    "sports-mix": (
        "Every sport except football: Olympics, athletics, tennis, "
        "motorsport, winter sports, cycling, combat sports, rules, records."
    ),
    "entertainment": (
        "Film, television, music, celebrities, streaming, awards, festivals, "
        "gaming and internet culture — including recent events."
    ),
    "science-nature": (
        "Science and the natural world: physics, chemistry, biology, space, "
        "the human body, animals, plants, weather, technology, inventions."
    ),
    "history": (
        "World history from prehistory to the late 20th century: rulers, "
        "wars, revolutions, empires, discoveries, everyday life of the past."
    ),
    "geography-world": (
        "Countries, cities, landmarks, flags, rivers, mountains, seas, "
        "peoples, languages, and how the world is organised."
    ),
    "movies-music": (
        "Cinema, television and music of every era: films, actors, "
        "directors, soundtracks, bands, albums, awards, famous lines."
    ),
    "sports": (
        "All sports: football, Olympics, tennis, motorsport, winter sports, "
        "athletics, records, rules, famous athletes and rivalries."
    ),
    "food-everyday": (
        "Food, drink, cooking, brands, shopping, transport, household life, "
        "hobbies and other everyday knowledge."
    ),
}

# International slice of the Kvíz, please! theme bank (128 regular episodes,
# 3 themes each). Czech/Slovak-national themes are deliberately left out —
# the corpus is English for an international audience.
INSPIRATION_THEMES: tuple[str, ...] = (
    "Japanese cuisine",
    "assassinations",
    "solving famous murders",
    "trams",
    "hotels",
    "streamers and streaming",
    "Formula 1",
    "towers",
    "youth slang",
    "the 2000s",
    "carnivores",
    "beer geography",
    "slogans",
    "LEGO",
    "film awards",
    "keys",
    "crafts and trades",
    "telenovelas",
    "robots",
    "dog breeds",
    "festivals",
    "bizarre laws",
    "famous trios",
    "Apple",
    "colours",
    "crime series",
    "Pokémon",
    "volleyball",
    "rivers and lakes",
    "frogs",
    "fantasy",
    "spices",
    "tools",
    "peninsulas",
    "gases",
    "aliens",
    "summer camps",
    "rodents",
    "ears",
    "silver",
    "Shakespeare",
    "the Mediterranean",
    "pregnancy",
    "kings and queens",
    "Thailand",
    "fictional places",
    "the microscopic world",
    "archaic words",
    "the seven deadly sins",
    "children of famous people",
    "women in politics",
    "vanished states",
    "horses",
    "Egypt",
    "reality shows",
    "dice",
    "international organisations",
    "British films and series",
    "British politics",
    "cocktails",
    "parks",
    "pressure",
    "everyday Latin",
    "Scandinavia",
    "reptiles",
    "vinyl records",
    "pub games",
    "film songs",
    "Greek myths",
    "microstates",
    "angels",
    "road signs",
    "feminism",
    "journalism",
    "board games",
    "gardens",
    "in which year",
    "musicals",
    "death",
    "badly described films",
    "conspiracy theories",
    "light and heavy",
    "unusual animals",
    "the journey of bread",
    "Hungarian cuisine",
    "idioms",
    "detective stories",
    "fast food",
    "prefixes",
    "in the forest",
    "punishments",
    "ghosts and haunted places",
    "paganism",
    "shopping malls",
    "primary-school maths",
    "dragons",
    "US units of measurement",
    "cryptozoology",
    "astrology",
    "lions",
    "siblings",
    "drugs",
    "beer",
    "roots",
    "major sports competitions",
    "who said it",
    "underwater",
    "heat",
    "villains",
    "winter",
    "East Asia",
    "holidays",
    "networks",
    "the USA",
    "Australia",
    "car makers",
    "stairs",
    "The Lord of the Rings",
    "20th-century music",
    "monarchies",
    "gambling",
    "walls",
    "motorways",
    "film music",
    "ships",
    "cooking",
    "love songs",
    "athletics",
    "seas",
    "fish",
    "playing cards",
    "trees",
    "ice",
    "winter sports",
    "bad songs",
    "Slavic languages",
    "candy and sweets",
    "reservoirs and dams",
    "cats",
    "World War II",
    "fabrics and materials",
    "South America",
    "dance",
    "art styles",
    "doctors",
    "cars",
    "fairy-tale characters",
    "tattoos",
    "stripes",
    "same initials",
    "law and justice",
    "famous film quotes",
    "water sports",
    "former Yugoslavia",
    "an ordinary day",
    "the post",
    "waves",
    "dinosaurs",
    "mottos",
    "James Bond",
    "phobias",
    "cycling",
    "diseases",
    "the Greek alphabet",
    "pseudonyms",
    "basketball",
    "beetles",
    "mountains",
    "memory",
    "homonyms",
    "gold",
    "zero",
    "tanks",
    "holes",
    "stars",
    "birds",
    "islands",
    "languages",
    "championships",
    "silence",
    "flying",
    "notable women",
    "foreign terms",
    "water",
    "famous murderers",
    "geometry",
    "round things",
    "Korea",
    "ice hockey",
    "plants",
    "famous duos",
    "Benelux",
    "rock and metal",
    "endangered species",
    "bubbles",
    "the human body",
    "fashion",
    "famous sentences",
    "hands",
    "tennis",
    "financial institutions",
    "fraudsters and scams",
    "antiquity",
    "artificial intelligence",
    "love",
    "Grand Theft Auto",
    "famous slogans",
    "halves",
    "faith",
    "drinks",
    "toys",
    "vegetables",
    "weather",
    "the Arabian Peninsula",
    "first aid",
    "writing systems",
    "US states",
    "poetry",
    "weapons",
    "mythological creatures",
    "Africa",
    "Star Wars",
    "the keyboard",
    "yellow",
    "flags",
    "-isms",
    "the seven wonders",
    "musical instruments",
    "time",
    "roads",
    "palindromes",
    "Hollywood",
    "mushrooms",
    "abbreviations",
    "laws",
    "giraffes",
    "numbers",
    "sitcoms",
    "safety",
    "YouTube",
    "public holidays",
    "British music",
    "world brands",
    "prehistory",
    "coffee",
    "gaming",
    "sports rules",
    "nicknames",
    "planet Earth",
    "TV game shows",
    "driving school",
    "dairy",
    "liquids",
    "Stargate",
    "finance",
    "the 90s",
    "transport",
    "Pixar",
    "the NHL",
    "card and board games",
    "trade",
    "famous quotes",
    "capital cities",
    "food",
    "literature",
    "social networks",
    "New York",
    "World War I",
    "famous couples",
    "inventions and inventors",
    "space",
    "history of IT",
    "the Olympic Games",
    "Europe",
)


class SubtopicProposal(BaseModel):
    """Structured answer for one category (function-calling schema)."""

    category: str = Field(description="The category id exactly as given in the brief.")
    subtopics: list[str] = Field(
        description="Subtopic names, each a short English noun phrase (max ~50 characters)."
    )


class ProposalError(ValueError):
    """The model's proposal violates the hand-off contract — nothing is written."""


_SYSTEM_PROMPT = """You design the topic map for a spoken trivia quiz app. Questions are \
written in English for a broad international adult audience, answered aloud in \
a few words (in the car, at a party, with family), and later served in several \
languages.

You will be given ONE category and asked for its subtopics. The subtopics are a \
coverage map: the generator is nudged towards the least-used subtopic each \
batch, so that a growing corpus stays varied instead of circling the same \
famous facts. They are SOFT hints (\"Preferred Topics\"), never fences — the \
writer keeps full creative freedom inside them."""

_HUMAN_TEMPLATE = """Category id: `{category}`
What this category means: {brief}

Propose {target} subtopics for this category.

Requirements:
1. **Broad, not narrow.** Every subtopic must be a territory that can host at \
least 50 distinct, non-overlapping questions. A single work, person, brand or \
event is too narrow (\"Shrek\" → \"Animated films and their characters\"; \
\"Formula 1\" → \"Motorsport\"). A whole category restated is too wide.
2. **Together they cover the category.** Aim for a near-complete, mostly \
non-overlapping split of the category's space — the classic pillars AND a few \
fresh angles a real quiz host would pick (origins and firsts, records and \
extremes, nicknames and pseudonyms, famous duos and rivalries, bizarre rules, \
things named after people, fictional places, everyday objects with a story…).
3. **International.** No subtopic that only makes sense for one country's \
audience.
4. **Answerable aloud.** Prefer territories whose answers are names, places, \
numbers or short phrases.
5. **Form.** Each subtopic is a short English noun phrase, at most 50 \
characters, no trailing punctuation, no numbering, no duplicates or \
near-duplicates.

For inspiration only — themes that real quiz shows found fun (use the ones that \
fit this category, ignore the rest, do not copy the list): {inspiration}.

Return the category id exactly as given and the list of subtopics."""


def build_messages(category: str, target: str = DEFAULT_TARGET) -> list:
    brief = CATEGORY_BRIEFS.get(category) or category.replace("-", " ")
    human = _HUMAN_TEMPLATE.format(
        category=category,
        brief=brief,
        target=target,
        inspiration=", ".join(INSPIRATION_THEMES),
    )
    return [SystemMessage(content=_SYSTEM_PROMPT), HumanMessage(content=human)]


def _build_llm(model: str):
    """Chat client on the active gateway (session → subscription, #169)."""
    return llm_factory.chat_openai(
        model, timeout=llm_factory.GENERATION_TIMEOUT, max_tokens=4096
    )


async def propose_category(
    llm, category: str, target: str = DEFAULT_TARGET
) -> SubtopicProposal:
    """One structured call for one category."""
    structured = llm.with_structured_output(
        SubtopicProposal, method="function_calling", include_raw=True
    )
    result = await structured.ainvoke(build_messages(category, target))
    parsed = result.get("parsed") if isinstance(result, dict) else result
    if not isinstance(parsed, SubtopicProposal):
        error = result.get("parsing_error") if isinstance(result, dict) else None
        raise ProposalError(
            f"{category}: model returned no structured proposal ({error or 'empty'})"
        )
    return parsed


def _normalize(name: str) -> str:
    return " ".join(name.split()).strip().lower()


def validate_proposal(
    payload: object, *, language: str, categories: Sequence[str]
) -> None:
    """Raise ``ProposalError`` unless ``payload`` is a complete, clean proposal.

    Schema: ``{language: {category: [subtopic, …]}}`` (D4) — exactly the
    requested language, exactly the requested categories (no extras, none
    missing), each list non-empty, strings only, no duplicates within a
    category (whitespace/case-insensitive), each name within the DB column.
    """
    if not isinstance(payload, dict) or set(payload) != {language}:
        raise ProposalError(f"top level must be exactly {{{language!r}: …}}")
    by_category = payload[language]
    if not isinstance(by_category, dict):
        raise ProposalError(f"{language}: expected a category → list mapping")
    expected, got = set(categories), set(by_category)
    if got - expected:
        raise ProposalError(
            f"categories outside the taxonomy: {sorted(got - expected)} "
            "(the model invented a category — refusing to write)"
        )
    if expected - got:
        raise ProposalError(
            f"categories missing from the proposal: {sorted(expected - got)} "
            "(the proposal is never trimmed to a subset of the taxonomy)"
        )
    for category, subtopics in by_category.items():
        if not isinstance(subtopics, list) or not subtopics:
            raise ProposalError(f"{category}: subtopics must be a non-empty list")
        if not MIN_SUBTOPICS <= len(subtopics) <= MAX_SUBTOPICS:
            raise ProposalError(
                f"{category}: {len(subtopics)} subtopics, expected "
                f"{MIN_SUBTOPICS}–{MAX_SUBTOPICS}"
            )
        seen: set[str] = set()
        for name in subtopics:
            if not isinstance(name, str) or not name.strip():
                raise ProposalError(
                    f"{category}: blank or non-string subtopic {name!r}"
                )
            if len(name) > MAX_SUBTOPIC_CHARS:
                raise ProposalError(
                    f"{category}: {name!r} is {len(name)} chars, column allows "
                    f"{MAX_SUBTOPIC_CHARS}"
                )
            key = _normalize(name)
            if key in seen:
                raise ProposalError(f"{category}: duplicate subtopic {name!r}")
            seen.add(key)


def assemble(
    proposals: dict[str, SubtopicProposal], *, language: str, categories: Sequence[str]
) -> dict:
    """Build the ``--out`` payload; a proposal filed under the wrong id fails."""
    by_category: dict[str, list[str]] = {}
    for category in categories:
        proposal = proposals[category]
        if proposal.category.strip().lower() != category:
            raise ProposalError(
                f"asked for {category!r}, model answered for {proposal.category!r}"
            )
        by_category[category] = [
            " ".join(s.split()).strip() for s in proposal.subtopics
        ]
    payload = {language: by_category}
    validate_proposal(payload, language=language, categories=categories)
    return payload


async def run(args: argparse.Namespace) -> dict:
    categories = [c.strip() for c in args.categories.split(",") if c.strip()]
    if not categories:
        raise ProposalError("no categories requested")
    llm = _build_llm(args.model)
    logger.info(
        "gateway=%s model=%s categories=%s",
        llm_factory.gateway(),
        args.model,
        categories,
    )
    results = await asyncio.gather(
        *(propose_category(llm, category, args.target) for category in categories)
    )
    proposals = dict(zip(categories, results))
    for category in categories:
        logger.info("%s: %d subtopics", category, len(proposals[category].subtopics))
    return assemble(proposals, language=args.language, categories=categories)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Propose per-category subtopics for founder review (#170 task 170.1)."
    )
    parser.add_argument(
        "--out", required=True, help="Proposal JSON path (only file written)."
    )
    parser.add_argument(
        "--language", default="en", help="Top-level language key (default: en)."
    )
    parser.add_argument(
        "--categories",
        default=",".join(CATEGORIES),
        help="Comma-separated category ids (default: the CATEGORIES taxonomy).",
    )
    parser.add_argument(
        "--model",
        default=llm_factory.GEN,
        help="Direct-provider model id; under LLM_GATEWAY=session it maps to the subscription tier.",
    )
    parser.add_argument(
        "--target",
        default=DEFAULT_TARGET,
        help="How many subtopics to ask for (default: 15-20).",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    logging.basicConfig(
        level=logging.INFO, format="%(levelname)s %(name)s: %(message)s"
    )
    args = build_parser().parse_args(argv)
    try:
        payload = asyncio.run(run(args))
    except ProposalError as exc:
        logger.error("proposal rejected: %s", exc)
        return 1
    except Exception as exc:  # noqa: BLE001 — any provider/transport failure is a rejected run
        logger.error("proposal failed: %s", exc)
        return 1
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    logger.info("wrote %s", args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
