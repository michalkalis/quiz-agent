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
    ) -> list[dict]:
        """Score a single question with all configured models.

        Returns list of {model_name, scores, overall_score}.
        """
        prompt = SCORING_PROMPT.format(
            question=question,
            answer=answer,
            difficulty=difficulty,
            topic=topic,
        )

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
                    "scores": {
                        k: v for k, v in data.items()
                        if k not in ("overall_score", "reasoning")
                        and isinstance(v, (int, float))
                    },
                    "overall_score": overall,
                    "reasoning": data.get("reasoning", ""),
                })

            except Exception as e:
                print(f"Scoring with {model_config['name']} failed: {e}")
                continue

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
