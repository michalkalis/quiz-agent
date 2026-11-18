"""#236 — the family mode's topic catalog („S deťmi“, plan issue-236-family-mode-build.md).

A family round plays ONE topic of ONE child age band. The topic lives on the
question as ``category = family-<topic>`` (no new column), and a question is
identified by the pair band + key, so the same key may sit in several bands
(Dinosaurs is in 4-6 and 7-9, each with its own questions).

The catalog is code on purpose: it changes by PR (names go through the copy
review), and ``GET /api/v1/family/topics`` shows a topic only when its band
has a whole round of playable questions in the asked language. Order in a
band = order on the Home deck (hobbies and games first, founder 2026-11-18).
Brand names are plain text, no logos (founder 2026-11-18); descriptive
fallbacks if App Review objects: „Stavebnice“, „Kockový svet“, „Svet
čarodejníkov“.
"""

from __future__ import annotations

from quiz_shared.models.question import AGE_BANDS

TOPIC_PREFIX = "family-"

# Founder 2026-11-18: 6 questions for 4-6, 10 for the older bands.
ROUND_SIZE: dict[str, int] = {"kids_4_6": 6, "kids_7_9": 10, "kids_10_12": 10}

# key → name per quiz language. A language without a name hides the topic
# there (Ukrainian has no family content yet, #231 — Ukrainian).
TOPIC_NAMES: dict[str, dict[str, str]] = {
    "family-dinosaurs": {"sk": "Dinosaury", "cs": "Dinosauři", "en": "Dinosaurs"},
    "family-animal-superpowers": {
        "sk": "Superschopnosti zvierat",
        "cs": "Superschopnosti zvířat",
        "en": "Animal superpowers",
    },
    "family-fairy-tales": {
        "sk": "Rozprávky a večerníčky",
        "cs": "Pohádky a večerníčky",
        "en": "Fairy tales",
    },
    "family-gross-but-true": {
        "sk": "Fuj, ale pravda",
        "cs": "Fuj, ale pravda",
        "en": "Gross but true",
    },
    "family-sounds-and-funny-words": {
        "sk": "Zvuky a smiešne slová",
        "cs": "Zvuky a legrační slova",
        "en": "Sounds and funny words",
    },
    "family-your-body": {"sk": "Tvoje telo", "cs": "Tvoje tělo", "en": "Your body"},
    "family-lego": {"sk": "LEGO", "cs": "LEGO", "en": "LEGO"},
    "family-minecraft": {"sk": "Minecraft", "cs": "Minecraft", "en": "Minecraft"},
    "family-pokemon": {"sk": "Pokémon", "cs": "Pokémon", "en": "Pokémon"},
    "family-football": {"sk": "Futbal", "cs": "Fotbal", "en": "Football"},
    "family-records": {"sk": "Rekordy", "cs": "Rekordy", "en": "World records"},
    "family-how-things-are-made": {
        "sk": "Ako sa čo vyrába",
        "cs": "Jak se co vyrábí",
        "en": "How things are made",
    },
    "family-harry-potter": {
        "sk": "Harry Potter",
        "cs": "Harry Potter",
        "en": "Harry Potter",
    },
    "family-roblox": {"sk": "Roblox", "cs": "Roblox", "en": "Roblox"},
    "family-spies-and-codes": {
        "sk": "Špióni a šifry",
        "cs": "Špioni a šifry",
        "en": "Spies and codes",
    },
    "family-could-it-work": {
        "sk": "Dalo by sa to?",
        "cs": "Šlo by to?",
        "en": "Could it work?",
    },
    "family-space": {"sk": "Vesmír", "cs": "Vesmír", "en": "Space"},
    "family-food-science": {
        "sk": "Jedlo ako veda",
        "cs": "Jídlo jako věda",
        "en": "Food science",
    },
}

BAND_TOPICS: dict[str, tuple[str, ...]] = {
    "kids_4_6": (
        "family-dinosaurs",
        "family-animal-superpowers",
        "family-fairy-tales",
        "family-gross-but-true",
        "family-sounds-and-funny-words",
        "family-your-body",
    ),
    "kids_7_9": (
        "family-lego",
        "family-minecraft",
        "family-pokemon",
        "family-football",
        "family-animal-superpowers",
        "family-dinosaurs",
        "family-gross-but-true",
        "family-records",
        "family-how-things-are-made",
    ),
    "kids_10_12": (
        "family-minecraft",
        "family-harry-potter",
        "family-roblox",
        "family-football",
        "family-spies-and-codes",
        "family-could-it-work",
        "family-records",
        "family-space",
        "family-food-science",
    ),
}


def is_band_topic(band: str, key: str) -> bool:
    """Whether ``key`` is a topic of ``band`` in the catalog."""
    return key in BAND_TOPICS.get(band, ())


def catalog_bands(language: str, counts: dict[tuple[str, str], int]) -> list[dict]:
    """Every band in order with its topics that have a whole round in
    ``language``. ``counts`` = playable questions per (band, category); a
    topic without a name in ``language`` is left out."""
    bands = []
    for band in AGE_BANDS:
        size = ROUND_SIZE[band]
        topics = [
            {"key": key, "name": TOPIC_NAMES[key][language], "round_size": size}
            for key in BAND_TOPICS[band]
            if language in TOPIC_NAMES[key] and counts.get((band, key), 0) >= size
        ]
        bands.append({"band": band, "topics": topics})
    return bands
