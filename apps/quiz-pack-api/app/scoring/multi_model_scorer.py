"""Score questions with multiple AI judges, one quality dimension per call.

2026-07-30 generation-review redesign (sections A3/A5/A6/C):

- **One dimension per call.** A single-pass multi-dimension rubric lets
  anchoring bleed across dimensions (a bad clever_framing dragged surprise
  down and vice versa); scoring each dimension in its own call keeps the
  judgments independent. Cost is a non-issue by founder policy (2026-07-30:
  generation pipeline always uses the best models, quality over cost).
- **Judges see the full question.** MCQ options and the resolved answer TEXT
  are rendered into every judge prompt — scoring an MCQ against a bare key
  letter ("b") made surprise/factual-confidence noise (A3).
- **`answerability` is a real dimension** (ported from question_critique_v2)
  so the scoring-stage veto reads the signal it documents instead of
  falling back to clever_framing (A5).
- **Deterministic overall.** `overall_score` is computed in code as the mean
  of the judged dimensions — never trusted from (or defaulted for) the LLM
  (A6). A judge whose call fails after one retry contributes nothing and the
  failure is logged loudly; a judge with zero parsed dimensions is dropped.
- **Judge families are disjoint from the generator.** Generation runs on a
  Claude model, so the judge pair is OpenAI + Google (self-preference bias,
  section C).

Deterministic advisory dimensions (#42 task 42.6) are unchanged: computed in
code, attached to every result entry.
"""

import asyncio
import json
import logging
import os
import re
from typing import Optional

from langchain_core.messages import HumanMessage

from quiz_shared.llm import factory as llm_factory

logger = logging.getLogger(__name__)

# Issue #42 task 42.6 — deterministic advisory dimensions. We compute
# these in code (not via the LLM) per CLAUDE.md rule #5: the criteria
# are explicit constraints, not classification. Logged into every
# scorer result so the orchestrator + post-gen validator (42.7) can
# act on them later.
_ANSWER_WORD_CAP = 10
_ANSWER_TAIL_MARKERS = (
    "—",  # em-dash
    "–",  # en-dash
    " because ",
    " namely ",
    " i.e.",
    " which means ",
)

# Bound on concurrent judge calls per score_batch (dimensions × judges ×
# questions fan out fast; the gateway tolerates ~10 in flight comfortably).
_MAX_CONCURRENT_CALLS = 10


def compute_answer_brevity(answer: object) -> int:
    """1-10 score; high = short, clean canonical answer.

    Penalises (a) word count above the cap and (b) explanation tails
    that the evaluator gives unfair partial credit for and TTS reads
    aloud during driving. Why these specific markers: the audit
    (42.1) found 20/441 questions where the tail was attached via
    em/en-dash or ``because``; those are exactly the patterns the
    auto-fix (42.2) splits on.
    """
    if answer is None:
        return 1
    text = ", ".join(str(a) for a in answer) if isinstance(answer, list) else str(answer)
    if not text.strip():
        return 1
    word_count = len(text.split())
    lowered = text.lower()
    has_tail = any(marker in lowered for marker in _ANSWER_TAIL_MARKERS)
    if word_count <= 5 and not has_tail:
        return 10
    if word_count <= _ANSWER_WORD_CAP and not has_tail:
        return 7
    if word_count > _ANSWER_WORD_CAP and has_tail:
        return 1
    return 3


def resolve_correct_answer(
    correct_answer: object,
    possible_answers: Optional[dict] = None,
) -> tuple[Optional[str], str]:
    """(key_letter, answer_text) for any stored answer shape.

    ``correct_answer`` arrives either as an option key ("b") or as the
    literal option text (post-pilot rows store TEXT); non-MCQ answers pass
    through. Judges must always see the TEXT — a bare key letter carries no
    information to score against (generation review A3).
    """
    text = str(correct_answer).strip()
    if not possible_answers:
        return None, text
    norm = text.lower()
    for k, v in possible_answers.items():
        if str(k).strip().lower() == norm:
            return str(k).strip().lower(), str(v).strip()
    for k, v in possible_answers.items():
        if str(v).strip().lower() == norm:
            return str(k).strip().lower(), str(v).strip()
    return None, text


def compute_distractor_quality(
    correct_answer: object,
    possible_answers: Optional[dict] = None,
) -> Optional[int]:
    """1-10 score for MCQ distractor plausibility; None when not MCQ.

    Why this matters: a distractor that contains the correct answer
    as a substring leaks the answer; a duplicate distractor makes
    the question unanswerable; wildly unbalanced lengths give the
    answer away by shape. These are the failure modes the plan
    (Track C) flags as "plausible distractors" requirements.

    ``correct_answer`` may be a key letter (``"a"``) or the literal
    value; both shapes are handled.
    """
    if not possible_answers or len(possible_answers) < 2:
        return None

    key, correct_value = resolve_correct_answer(correct_answer, possible_answers)
    if key is None and correct_value.lower() not in {
        str(v).strip().lower() for v in possible_answers.values()
    }:
        return None

    distractors = [
        str(v).strip()
        for k, v in possible_answers.items()
        if str(v).strip().lower() != correct_value.lower()
    ]
    if not distractors:
        return 1

    score = 10
    seen: set[str] = set()
    correct_low = correct_value.lower()
    for d in distractors:
        d_low = d.lower()
        if d_low == correct_low:
            score -= 4
        elif len(d_low) > 2 and len(correct_low) > 2:
            if d_low in correct_low or correct_low in d_low:
                score -= 3
        if d_low in seen:
            score -= 4
        seen.add(d_low)
        if correct_value:
            ratio = len(d) / max(1, len(correct_value))
            if ratio > 3 or ratio < 1 / 3:
                score -= 1
    return max(1, min(10, score))


_DETERMINISTIC_DIMS_KEY = "deterministic"

# Shared context header for every per-dimension call. The calibration lens
# matches the generation prompt's: voice-first, one listen, non-native
# English player.
_CONTEXT_HEADER = """You are evaluating ONE trivia quiz question on ONE quality dimension. The question is read aloud once in a voice-first quiz played hands-free while driving, so it must land on a single listen and the answer must be short and gradable. The target player is a non-native English speaker — judge obscurity and difficulty through that lens (a term natives find easy may be genuinely fresh to them, and vice versa).

QUESTION: {question}
{options_block}CORRECT ANSWER: {answer}
DIFFICULTY: {difficulty}
TOPIC: {topic}

Score calibration: most questions land at 4-7. 9-10 is rare (top 5%). If you would score almost everything 7+, you are inflating — recalibrate against the anchors below.

DIMENSION TO SCORE — {dim_title}:
{dim_rubric}

Respond in JSON only:
{{"score": <integer 1-10>, "reasoning": "<one short sentence>"}}"""

# Per-dimension rubrics. Anchors come from the product owner's rated ground
# truth (multi_model_scorer history + question_critique_v2, founder-calibrated
# 2026-07-09/15). One dimension per call by design — do not merge these back
# into a single prompt (anchoring bleeds across dimensions).
SCORING_DIMENSIONS: dict[str, dict[str, str]] = {
    "conversation_spark": {
        "title": "Conversation Spark",
        "rubric": (
            "Would this question generate discussion at a pub quiz table?\n"
            "- 9-10: sparks debate, guesses and stories before the reveal\n"
            "- 5-6: mildly discussable, one or two guesses then silence\n"
            "- 1-3: nothing to discuss — you know it or you don't"
        ),
    },
    "surprise_delight": {
        "title": "Surprise / Delight",
        "rubric": (
            'Does the answer create an "aha!" / "never realised that" moment?\n'
            '- 9-10 anchor: "Was Cleopatra closer in time to the pyramids or '
            'the Moon landings?" (Moon); mantis-shrimp strike creating a light '
            "flash (cavitation).\n"
            '- 1-3 anchor: overexposed staples — "all roads lead to Rome", '
            'Michael Jackson "King of Pop". If the fact has been on a thousand '
            "quizzes, score 1-3 regardless of how well it is worded.\n"
            "- 1-3 anchor: single-fact lookups with no reveal behind them — "
            '"Which element is named after the creator of the periodic '
            'table?" (Mendelevium). Naming a thing from its best-known '
            "attribute surprises no one."
        ),
    },
    "tellability": {
        "title": "Tellability",
        "rubric": (
            "Would the player share this fact with a friend later?\n"
            "- 9-10: a story you retell the same day\n"
            "- 5-6: interesting in the moment, forgotten by the next question\n"
            "- 1-3: nothing to retell"
        ),
    },
    "driving_friendliness": {
        "title": "Driving Friendliness",
        "rubric": (
            "Comfortable to process on ONE listen while driving? Penalise "
            "padded multi-clue stems: a question gets ONE sharp clue, not a "
            "pile.\n"
            "- 9-10: one idea, one clue, instantly graspable\n"
            "- 4-6: needs mild mental replay (long stem, stacked descriptors)\n"
            "- 1-3: nested negation, double conditions, unit conversions, or "
            "anything demanding a second listen"
        ),
    },
    "clever_framing": {
        "title": "Clever Framing",
        "rubric": (
            'Avoids boring "What is..." recall AND avoids these craft defects '
            "(each caps this dimension at 3):\n"
            "- Stem answer-leak: a word in the stem gives the answer away or "
            "trivially implies it.\n"
            '- Telegraphed true/false: a T/F statement phrased so "True" is '
            "the obvious guess.\n"
            "- Clue-pile stem: two or more descriptors of the same referent "
            "stacked up. One sharp hook is craft; a list of properties is not. "
            "(Distinct clues that each open a DIFFERENT deduction path are "
            "fine.)\n"
            "- Landmark giveaway: the stem names an identifier so tied to the "
            "answer that answering is passive recognition.\n"
            '- Vague "what is special about X" stem whose answer is an '
            "explanation sentence rather than a short fact.\n"
            '- Bare first-degree recall: "Who directed X" / "Which element is '
            'named after Y" lookups cap at 3 even when flawlessly worded.\n'
            "- Deductive giveaway: the stem's framing lets a player with ZERO "
            "knowledge derive the answer — a stereotype, a famous-person "
            "pattern, or elimination (British tank's boiling vessel → tea; "
            '"only U.S. state made of two peninsulas" → Michigan).\n'
            "- Unanchored referent: an unglossed rare term, a record with no "
            "date, or a perceptual claim with no vantage point.\n"
            "- Convoluted stem: phrasing that needs a second pass when heard "
            "once."
        ),
    },
    "factual_confidence": {
        "title": "Factual Confidence",
        "rubric": (
            "How confident are you the stated answer is correct? (10 = "
            "certain). For MCQ also check: exactly one option is defensibly "
            "correct — if a distractor is arguably also right, score 1-4."
        ),
    },
    # Generation review A5: the scoring-stage veto documents an
    # answerability/surprise AND-gate; this dimension (ported from
    # question_critique_v2, same anchors) makes that signal real instead of
    # aliasing to clever_framing.
    "answerability": {
        "title": "Answerability / Engagement Path",
        "rubric": (
            "Can the player reason, estimate, or deduce toward the answer "
            "(instead of only recalling it)?\n"
            '- 9-10 anchor: "Which is heavier: all ants on Earth or all '
            'humans?" (estimable)\n'
            '- 7 anchor: "Was Cleopatra closer to the pyramids or the Moon '
            'landing?" (timeline reasoning)\n'
            '- 5 anchor: "Which spice was traded for Manhattan?" (can guess '
            "the category, not the item)\n"
            '- 2 anchor: "Which English word has 3 consecutive double '
            'letters?" (impossible to deduce)\n'
            "For MCQ, judge the reasoning path across the given options: "
            "plausible-but-eliminable distractors raise this score; "
            "coin-flip options lower it."
        ),
    },
}


def _format_options_block(possible_answers: Optional[dict]) -> str:
    """Render MCQ options for the judge prompt ('' for non-MCQ)."""
    if not possible_answers:
        return ""
    rendered = " | ".join(
        f"{str(k).lower()}) {v}" for k, v in possible_answers.items()
    )
    return f"OPTIONS: {rendered}\n"


def _parse_dim_response(text: str) -> Optional[tuple[float, str]]:
    """Extract (score, reasoning) from a judge response, or None."""
    cleaned = text.strip()
    if cleaned.startswith("```"):
        cleaned = cleaned.split("\n", 1)[-1].rsplit("```", 1)[0].strip()
    start = cleaned.find("{")
    end = cleaned.rfind("}") + 1
    if start == -1 or end <= start:
        return None
    try:
        data = json.loads(cleaned[start:end])
    except json.JSONDecodeError:
        return None
    score = data.get("score")
    if not isinstance(score, (int, float)):
        # Tolerate {"score": "8"} but nothing woollier.
        if isinstance(score, str) and re.fullmatch(r"\d+(\.\d+)?", score.strip()):
            score = float(score.strip())
        else:
            return None
    score = float(score)
    if not 1.0 <= score <= 10.0:
        return None
    return score, str(data.get("reasoning", ""))


class MultiModelScorer:
    """Score questions using multiple AI judges, one dimension per call."""

    def __init__(self, models: Optional[list[dict]] = None):
        """Initialize with a list of judges.

        Args:
            models: List of model configs, each with:
                - provider: "openai" | "google" | "anthropic"
                - model: model name (factory direct id)
                - name: display name for tracking
        """
        self.models = models or self._default_models()
        self._clients: dict = {}

    @staticmethod
    def _default_models() -> list[dict]:
        """Default judge pair: OpenAI + Google frontier (2026-07-30 refresh).

        Families are disjoint from the Claude generation model (LLM-judge
        self-preference bias, generation review section C). In the OpenRouter
        gateway both judges share one key (``OPENROUTER_API_KEY``); in direct
        mode each provider is gated on its own key — without one that judge is
        dropped, as before.
        """
        openrouter = llm_factory.gateway() == llm_factory.OPENROUTER

        def _enabled(direct_key: str) -> bool:
            if openrouter:
                return bool(os.getenv("OPENROUTER_API_KEY"))
            return bool(os.getenv(direct_key))

        models = []
        if _enabled("OPENAI_API_KEY"):
            models.append({
                "provider": "openai",
                "model": llm_factory.SCORE_OPENAI,
                "name": llm_factory.SCORE_OPENAI,
                "temperature": 0.3,
            })
        if _enabled("GOOGLE_API_KEY"):
            models.append({
                "provider": "google",
                "model": llm_factory.SCORE_GOOGLE,
                "name": llm_factory.SCORE_GOOGLE,
                "temperature": 0.3,
            })
        return models

    def _get_client(self, model_config: dict):
        """Get or create the LLM client for a judge config.

        All judges go through the factory chat client: in the OpenRouter
        gateway one endpoint serves the OpenAI and Google models alike; in
        direct mode it is the canonical provider endpoint. The factory remaps
        the model id to the active gateway's slug and drops sampling params
        for families that reject them.
        """
        name = model_config["name"]
        if name not in self._clients:
            self._clients[name] = llm_factory.chat_openai(
                model_config["model"],
                temperature=model_config.get("temperature", 0.3),
            )
        return self._clients[name]

    async def _score_dimension(
        self,
        model_config: dict,
        dim_key: str,
        prompt: str,
        semaphore: Optional[asyncio.Semaphore] = None,
    ) -> Optional[tuple[float, str]]:
        """One judge × one dimension, with a single retry on failure.

        Returns (score, reasoning) or None after the retry — the caller logs
        the miss; nothing is silently defaulted (generation review A6).
        """
        client = self._get_client(model_config)
        for attempt in (1, 2):
            try:
                if semaphore is not None:
                    async with semaphore:
                        response = await client.ainvoke([HumanMessage(content=prompt)])
                else:
                    response = await client.ainvoke([HumanMessage(content=prompt)])
                parsed = _parse_dim_response(response.content)
                if parsed is not None:
                    return parsed
                logger.warning(
                    "Judge %s returned unparseable %s response (attempt %d)",
                    model_config["name"], dim_key, attempt,
                )
            except Exception as exc:  # noqa: BLE001 — judge call boundary
                logger.warning(
                    "Judge %s failed on %s (attempt %d): %r",
                    model_config["name"], dim_key, attempt, exc,
                )
        return None

    async def score_question(
        self,
        question: str,
        answer: str,
        difficulty: str = "medium",
        topic: str = "General",
        possible_answers: Optional[dict] = None,
        semaphore: Optional[asyncio.Semaphore] = None,
    ) -> list[dict]:
        """Score a single question with all judges, one dimension per call.

        Returns list of {model_name, scores, overall_score, reasoning}. Every
        entry's ``scores`` dict carries ``answer_brevity`` (always) and
        ``distractor_quality`` (MCQ only) — issue #42 task 42.6. A judge with
        zero parsed dimensions is dropped (logged); when no judge returns
        anything, a synthetic ``deterministic`` entry is emitted so the
        advisory dims are always logged. ``overall_score`` is always computed
        here as the mean of the judged dimensions — never taken from the LLM.
        """
        _, answer_text = resolve_correct_answer(answer, possible_answers)
        options_block = _format_options_block(possible_answers)

        brevity = compute_answer_brevity(answer_text)
        distractor = compute_distractor_quality(answer, possible_answers)

        def _attach_dims(scores: dict) -> dict:
            scores["answer_brevity"] = brevity
            if distractor is not None:
                scores["distractor_quality"] = distractor
            return scores

        dim_items = list(SCORING_DIMENSIONS.items())
        prompts = {
            dim_key: _CONTEXT_HEADER.format(
                question=question,
                options_block=options_block,
                answer=answer_text,
                difficulty=difficulty,
                topic=topic,
                dim_title=spec["title"],
                dim_rubric=spec["rubric"],
            )
            for dim_key, spec in dim_items
        }

        results = []
        for model_config in self.models:
            dim_results = await asyncio.gather(*(
                self._score_dimension(model_config, dim_key, prompts[dim_key], semaphore)
                for dim_key, _ in dim_items
            ))

            scores: dict = {}
            reasonings: list[str] = []
            for (dim_key, _), outcome in zip(dim_items, dim_results):
                if outcome is None:
                    continue
                score, reasoning = outcome
                scores[dim_key] = score
                if reasoning:
                    reasonings.append(f"{dim_key}: {reasoning}")

            missing = len(dim_items) - len(scores)
            if not scores:
                logger.warning(
                    "Judge %s produced no scores for question %r — dropped",
                    model_config["name"], question[:80],
                )
                continue
            if missing:
                logger.warning(
                    "Judge %s missing %d/%d dimensions for question %r",
                    model_config["name"], missing, len(dim_items), question[:80],
                )

            overall = round(sum(scores.values()) / len(scores), 2)
            results.append({
                "model_name": model_config["name"],
                "scores": _attach_dims(dict(scores)),
                "overall_score": overall,
                "reasoning": " | ".join(reasonings),
            })

        if not results:
            results.append({
                "model_name": _DETERMINISTIC_DIMS_KEY,
                "scores": _attach_dims({}),
                "overall_score": float(brevity),
                "reasoning": "deterministic-only (no LLM result available)",
            })

        return results

    async def score_batch(
        self,
        questions: list[dict],
        sql_client=None,
    ) -> list[dict]:
        """Score a batch of questions with all judges, concurrently.

        Args:
            questions: List of {id, question, correct_answer, difficulty, topic}
            sql_client: Optional SQLClient to persist scores

        Returns:
            List of {id, model_scores: [{model_name, scores, overall_score}]}
        """
        semaphore = asyncio.Semaphore(_MAX_CONCURRENT_CALLS)

        async def _score_one(q: dict) -> dict:
            scores = await self.score_question(
                question=q["question"],
                answer=str(q["correct_answer"]),
                difficulty=q.get("difficulty", "medium"),
                topic=q.get("topic", "General"),
                possible_answers=q.get("possible_answers"),
                semaphore=semaphore,
            )
            return {"id": q.get("id", "unknown"), "model_scores": scores}

        results = list(await asyncio.gather(*(_score_one(q) for q in questions)))

        if sql_client:
            for r in results:
                for s in r["model_scores"]:
                    sql_client.add_model_score(
                        question_id=r["id"],
                        scored_by=s["model_name"],
                        scores=s["scores"],
                        overall_score=s["overall_score"],
                    )

        return results
