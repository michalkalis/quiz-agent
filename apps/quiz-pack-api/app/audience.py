"""Who a custom pack is written for (#236 task 236.1).

A content setting on the order ("questions for 7-9"), never a fact about a
person: nothing here describes the buyer or a player, and no account or
profile carries it. NULL (orders from builds before the choice) and "adults"
mean the same pack: today's adult generation, untouched.

A child band changes three things, all keyed on `is_child`: the generation
prompt (`prompts/question_generation_direct_kids.md`), a post-generation check
(`app.kids_check`) and the pre-payment topic check's tier (`app.topic_check`).
Band and difficulty are separate axes: the band sets vocabulary, length and
question shape; difficulty is relative WITHIN the band.
"""

from __future__ import annotations

from typing import Literal, NamedTuple

Audience = Literal["adults", "kids_4_6", "kids_7_9", "kids_10_12"]
AUDIENCES: tuple[str, ...] = ("adults", "kids_4_6", "kids_7_9", "kids_10_12")


class BandLimits(NamedTuple):
    """Word caps the server enforces after generation (`app.kids_check`).
    The prompt quotes the same numbers, so the two cannot drift apart."""

    question_words: int
    answer_words: int
    explanation_words: int


LIMITS: dict[str, BandLimits] = {
    "kids_4_6": BandLimits(question_words=14, answer_words=2, explanation_words=20),
    "kids_7_9": BandLimits(question_words=20, answer_words=3, explanation_words=28),
    "kids_10_12": BandLimits(question_words=28, answer_words=4, explanation_words=36),
}

LABELS: dict[str, str] = {"kids_4_6": "4-6", "kids_7_9": "7-9", "kids_10_12": "10-12"}

# Vocabulary and question shape per band. Kept next to the limits because the
# section quotes them.
_SHAPE: dict[str, str] = {
    "kids_4_6": (
        "Preschoolers. A parent may read the question and tap the answer for "
        "them. EVERY question is one of two shapes, nothing else:\n"
        "- a yes/no question: `type` = \"text_multichoice\" with exactly two "
        "options, \"Yes\" and \"No\" written in the pack's language (never "
        "\"True\"/\"False\");\n"
        "- pick one of two: `type` = \"text_multichoice\" with exactly two "
        "short options.\n"
        "This overrides the batch composition and the option counts in the "
        "multiple-choice section below: here every question is a two-option "
        "MCQ. Things a small child sees every day: animals, colours, food, "
        "home, toys, the body, weather, simple shapes and sizes. Words a "
        "four-year-old uses; one short sentence."
    ),
    "kids_7_9": (
        "Early school years. Everyday words; a hard word only when it IS the "
        "answer and the question leads the child to it. One sentence, two at "
        "most."
    ),
    "kids_10_12": (
        "Older primary school. A little reasoning or a fun connection is "
        "welcome. Plain words, no jargon. One or two short sentences."
    ),
}


def is_child(audience: str | None) -> bool:
    return audience in LIMITS


def band_section(audience: str) -> str:
    """The per-band block of the kids prompt (`{band_section}`)."""
    limits = LIMITS[audience]
    return (
        f"**Age band: {LABELS[audience]} years.**\n\n"
        f"{_SHAPE[audience]}\n\n"
        f"Hard length limits (longer questions are discarded by the server): "
        f"`question` at most {limits.question_words} words, the answer "
        f"(`correct_answer`, or each option's text) at most "
        f"{limits.answer_words} words, `explanation` at most "
        f"{limits.explanation_words} words."
    )


def difficulty_player(audience: str) -> str:
    """Who the difficulty rubric is calibrated for, for a child band."""
    return (
        f"a child aged {LABELS[audience]} (difficulty is relative to this age "
        "band: an easy question for this band is easy for most children of "
        "this age, a hard one is hard for them; never change the age band to "
        "change the difficulty)"
    )
