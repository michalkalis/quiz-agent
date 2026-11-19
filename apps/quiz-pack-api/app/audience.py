"""Who a custom pack is written for (#236 task 236.1).

A content setting on the order ("questions for 7-9"), never a fact about a
person: nothing here describes the buyer or a player, and no account or
profile carries it. NULL (orders from builds before the choice) and "adults"
mean the same pack: today's adult generation, untouched.

A child band changes these things, all keyed on `is_child`: the generation
prompt (`prompts/question_generation_direct_kids.md`), a post-generation check
(`app.kids_check`), the pre-payment topic check's tier (`app.topic_check`),
the audience the quality judges score for (`judge_lens`: the judge panel in
`app.scoring.multi_model_scorer` and `app.verification.casual_player`) and the
true/false cap (`app.orchestrator.stages.composition`). Band and difficulty
are separate axes: the band sets vocabulary, length and question shape;
difficulty is relative WITHIN the band.
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
    # The largest number a child may be asked to say or pick as the answer.
    answer_number: int


# Answer caps (founder 2026-11-15): 7-9 and 10-12 were 3 and 4 words, which
# dropped a good short "why" answer ("There is no wind there", 5 words) as
# answer_too_long. 6 matches the adult spoken-answer ruling (`craft_guards.
# _ANSWER_MAX_WORDS`), so a longer cap would only move the drop there. 4-6
# stays at 2: a preschooler answers in a word or two, or the parent taps.
#
# Number caps (founder 2026-11-17, second trial): children cannot picture
# large numbers, so "how many ways can six bricks join: a hundred, a
# thousand, a million, almost a billion?" is a blind guess, not a question.
# Small counts they can picture are fine. The exact caps are a judgment call.
LIMITS: dict[str, BandLimits] = {
    "kids_4_6": BandLimits(
        question_words=14, answer_words=2, explanation_words=20, answer_number=10
    ),
    "kids_7_9": BandLimits(
        question_words=20, answer_words=6, explanation_words=28, answer_number=100
    ),
    "kids_10_12": BandLimits(
        question_words=28, answer_words=6, explanation_words=36, answer_number=1000
    ),
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
        "four-year-old uses; one short sentence.\n"
        # Founder on the pilot, 2026-11-18: "too obvious", "written too
        # childishly, almost primitive"; the "why" in the explanation was the
        # part he liked ("children learn why it happens").
        "Simple is not the same as obvious. Never ask what every child of "
        "this age already knows for sure (\"Does it hurt when your hair is "
        "cut?\", \"Can your tummy rumble when you are hungry?\"): there is "
        "nothing to think about. When the fact itself is known to the child, "
        "ask about the surprising reason instead, as a pick of two (\"Why "
        "does a haircut not hurt? Hair cannot feel / The scissors are "
        "gentle\"), or find a fact a child would honestly have to guess. "
        "Both options must be plausible to a small child.\n"
        "Plain words, not baby talk: write the way a kind adult talks to a "
        "child, with the ordinary word for a thing. No pet names or "
        "diminutives for body parts and everyday things in the pack's "
        "language (in Slovak or Czech: \"srdce\", \"brucho\", \"jesť\", never "
        "\"srdiečko\", \"bruško\", \"papať\")."
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
        f"{limits.explanation_words} words.\n\n"
        f"Numbers: a child of this age cannot picture large numbers, so never "
        f"make the answer a large number to guess. No number above "
        f"{limits.answer_number} in the answer or in any option, in digits or "
        f"in words (thousands, a million), and no options that differ by "
        f"tenfold steps (4, 40, 400, 4,000); the server discards those too. "
        f"Small counts a child can picture are fine. A big number may appear "
        f"in the explanation next to something the child knows (\"as heavy as "
        f"five grown-ups\"); better still, ask about that comparison instead "
        f"of the number."
    )


def judge_lens(audience: str) -> str:
    """Who a quality judge scores for, for a child band.

    The judge prompts were written and calibrated for adults (pub quiz,
    driving, a non-native English adult). Founder 2026-11-15: "fun for an
    adult is not fun for a child, nor for a child of a different age". This
    paragraph re-aims the same rubric at the band; the judges, the scales
    and the thresholds stay as they are.
    """
    return (
        f"AUDIENCE: the player is a child aged {LABELS[audience]}, playing "
        "together with a parent who reads the question aloud. This replaces "
        "the player described above and every adult reference below: judge "
        "fun, difficulty, answerability and words for a child of THIS age, "
        "not for an adult. What delights an adult often bores a child, and a "
        "fact adults have heard a thousand times can be new and exciting to "
        "a child of this age (and the reverse). Read \"a pub quiz table\" as "
        "the family playing together and \"a friend\" as a parent, sibling "
        "or classmate. Score high: facts about the child's own body, home, "
        "food and everyday things, things they can try or check right away, "
        "the biggest/fastest/smelliest, funny or gross-but-harmless facts. "
        "Score low: abstract textbook facts with no link to a child's world. "
        "Reasoning from everyday experience toward the answer is the path we "
        "want a child to have, not a giveaway. A word a child of this age "
        "does not know counts against the question unless it IS the answer "
        "and the question leads the child to it."
    )


def difficulty_player(audience: str) -> str:
    """Who the difficulty rubric is calibrated for, for a child band."""
    return (
        f"a child aged {LABELS[audience]} (difficulty is relative to this age "
        "band: an easy question for this band is easy for most children of "
        "this age, a hard one is hard for them; never change the age band to "
        "change the difficulty)"
    )
