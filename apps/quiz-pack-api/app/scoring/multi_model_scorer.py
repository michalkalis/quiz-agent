"""Score questions with multiple AI models for A/B testing.

Evaluates each question across several models to determine which model
is the best judge of question quality. Results are stored in SQLite
for correlation analysis with user ratings.
"""

import json
import os
from typing import Optional

from langchain_openai import ChatOpenAI
from langchain_core.messages import HumanMessage

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

    correct_norm = str(correct_answer).strip().lower()
    correct_value: Optional[str] = None
    if correct_norm in {str(k).strip().lower() for k in possible_answers}:
        for k, v in possible_answers.items():
            if str(k).strip().lower() == correct_norm:
                correct_value = str(v).strip()
                break
    else:
        for v in possible_answers.values():
            if str(v).strip().lower() == correct_norm:
                correct_value = str(v).strip()
                break
    if not correct_value:
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

SCORING_PROMPT = """You are evaluating a trivia quiz question for quality and fun.

QUESTION: {question}
CORRECT ANSWER: {answer}
DIFFICULTY: {difficulty}
TOPIC: {topic}

Rate this question on each dimension (1-10 scale):

1. **Conversation Spark** - Would this generate discussion at a pub quiz table?
2. **Surprise/Delight** - Does the answer create an "aha!" moment or a grin?
3. **Tellability** - Would you share this with a friend later?
4. **Driving Friendliness** - Comfortable to process while driving? (not too complex)
5. **Clever Framing** - Avoids boring "What is..." format?
6. **Factual Confidence** - How confident are you the answer is correct? (10 = certain)

Respond in JSON only:
{{
  "conversation_spark": 8,
  "surprise_delight": 7,
  "tellability": 9,
  "driving_friendliness": 8,
  "clever_framing": 7,
  "factual_confidence": 9,
  "overall_score": 8.0,
  "reasoning": "Brief explanation of your ratings"
}}"""


class MultiModelScorer:
    """Score questions using multiple AI models for comparison."""

    def __init__(self, models: Optional[list[dict]] = None):
        """Initialize with a list of models to use.

        Args:
            models: List of model configs, each with:
                - provider: "openai" | "anthropic" | "google"
                - model: model name
                - name: display name for tracking
        """
        self.models = models or self._default_models()
        self._clients: dict[str, ChatOpenAI] = {}

    @staticmethod
    def _default_models() -> list[dict]:
        """Default models for scoring A/B test."""
        models = []
        if os.getenv("OPENAI_API_KEY"):
            models.append({
                "provider": "openai",
                "model": "gpt-4.1-mini",
                "name": "gpt-4.1-mini",
                "temperature": 0.3,
            })
        if os.getenv("ANTHROPIC_API_KEY"):
            models.append({
                "provider": "anthropic",
                "model": "claude-sonnet-4-6",
                "name": "claude-sonnet-4.6",
                "temperature": 0.3,
            })
        return models

    def _get_client(self, model_config: dict):
        """Get or create LLM client for a model config."""
        name = model_config["name"]
        if name not in self._clients:
            provider = model_config["provider"]
            if provider == "openai":
                self._clients[name] = ChatOpenAI(
                    model=model_config["model"],
                    temperature=model_config.get("temperature", 0.3),
                )
            elif provider == "anthropic":
                from langchain_anthropic import ChatAnthropic
                self._clients[name] = ChatAnthropic(
                    model=model_config["model"],
                    temperature=model_config.get("temperature", 0.3),
                )
            elif provider == "google":
                from langchain_google_genai import ChatGoogleGenerativeAI
                self._clients[name] = ChatGoogleGenerativeAI(
                    model=model_config["model"],
                    temperature=model_config.get("temperature", 0.3),
                )
        return self._clients[name]

    async def score_question(
        self,
        question: str,
        answer: str,
        difficulty: str = "medium",
        topic: str = "General",
        possible_answers: Optional[dict] = None,
    ) -> list[dict]:
        """Score a single question with all configured models.

        Returns list of {model_name, scores, overall_score}. Every
        entry's ``scores`` dict carries ``answer_brevity`` (always)
        and ``distractor_quality`` (MCQ only) — issue #42 task 42.6.
        When no model returns a parseable result, a synthetic
        ``deterministic`` entry is emitted so the advisory dims are
        always logged.
        """
        prompt = SCORING_PROMPT.format(
            question=question,
            answer=answer,
            difficulty=difficulty,
            topic=topic,
        )

        brevity = compute_answer_brevity(answer)
        distractor = compute_distractor_quality(answer, possible_answers)

        def _attach_dims(scores: dict) -> dict:
            scores["answer_brevity"] = brevity
            if distractor is not None:
                scores["distractor_quality"] = distractor
            return scores

        results = []
        for model_config in self.models:
            try:
                client = self._get_client(model_config)
                response = await client.ainvoke([HumanMessage(content=prompt)])

                # Parse JSON from response
                text = response.content.strip()
                if text.startswith("```"):
                    text = text.split("\n", 1)[1].rsplit("```", 1)[0].strip()

                start = text.find("{")
                end = text.rfind("}") + 1
                if start == -1 or end <= start:
                    continue

                data = json.loads(text[start:end])
                overall = float(data.get("overall_score", 5.0))

                results.append({
                    "model_name": model_config["name"],
                    "scores": _attach_dims({
                        k: v for k, v in data.items()
                        if k not in ("overall_score", "reasoning")
                        and isinstance(v, (int, float))
                    }),
                    "overall_score": overall,
                    "reasoning": data.get("reasoning", ""),
                })

            except Exception as e:
                print(f"Scoring with {model_config['name']} failed: {e}")
                continue

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
        """Score a batch of questions with all models.

        Args:
            questions: List of {id, question, correct_answer, difficulty, topic}
            sql_client: Optional SQLClient to persist scores

        Returns:
            List of {id, model_scores: [{model_name, scores, overall_score}]}
        """
        results = []
        for q in questions:
            scores = await self.score_question(
                question=q["question"],
                answer=str(q["correct_answer"]),
                difficulty=q.get("difficulty", "medium"),
                topic=q.get("topic", "General"),
                possible_answers=q.get("possible_answers"),
            )

            if sql_client:
                for s in scores:
                    sql_client.add_model_score(
                        question_id=q.get("id", "unknown"),
                        scored_by=s["model_name"],
                        scores=s["scores"],
                        overall_score=s["overall_score"],
                    )

            results.append({
                "id": q.get("id", "unknown"),
                "model_scores": scores,
            })

        return results
