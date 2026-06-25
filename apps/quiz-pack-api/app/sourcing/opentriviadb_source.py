"""Open Trivia Database source — extracts underlying facts from trivia questions."""

import html
import os
from typing import Optional

import httpx

from quiz_shared.llm import factory as llm_factory

from .models import Fact


# Map opentdb category IDs to topic names. `_map_topics_to_categories` matches
# these values verbatim (lowercased) against order topics — do NOT rename the
# existing entries below or topic matching silently breaks. #42 task 42.28
# widened the map from 10 → 24 against the real opentdb category list so
# prompt-derived topics like "film", "mythology" or "politics" resolve to a
# real category instead of falling back to General.
CATEGORY_MAP = {
    9: "General",
    17: "Science",
    18: "Technology",
    22: "Geography",
    23: "History",
    25: "Art",
    27: "Nature",
    12: "Music",
    21: "Sports",
    15: "Entertainment",
    # #42 task 42.28 — added opentdb categories (accurate IDs, topic-friendly names).
    10: "Books",
    11: "Film",
    13: "Theatre",
    14: "Television",
    16: "Board Games",
    19: "Mathematics",
    20: "Mythology",
    24: "Politics",
    26: "Celebrities",
    28: "Vehicles",
    29: "Comics",
    30: "Gadgets",
    31: "Anime",
    32: "Cartoons",
}


def _fact_echoes_question(fact_text: str, question: str) -> bool:
    """RC-1 guard: ``True`` when a rewritten fact still embeds the original
    trivia question verbatim — i.e. the re-wrap (``The answer to '<question>'
    is <answer>.``) we are trying to eliminate. The trailing ``?`` is stripped
    so a declarative rewrite that merely drops the question mark is still
    caught. Comparison is case-insensitive and substring-based per the issue's
    "output never contains the original-question substring" spec.
    """
    q = question.strip().rstrip("?").strip().lower()
    return bool(q) and q in fact_text.lower()


_REWRITE_PROMPT = """Turn this trivia question and its correct answer into a single, self-contained declarative fact a quiz writer can build a NEW question from.

QUESTION: {question}
ANSWER: {answer}

Rules:
- State the underlying fact directly. Do NOT repeat or paraphrase the question, and do NOT write "the answer is ...".
- One sentence, <= 25 words, factually faithful to the answer.
- Output ONLY the sentence — no quotes, labels, or preamble."""


class OpenTriviaFactRewriter:
    """Cheap-model rewriter that turns a trivia Q+A into a bare declarative
    fact (RC-1). Mirrors ``AnswerNormalizer``'s lazy ``llm_factory`` client and
    fail-safe contract: any unavailability, exception, or empty output returns
    ``None`` so the caller drops the seed rather than emitting a re-wrap. Routed
    through the #53 factory — never instantiates an SDK client directly.
    """

    def __init__(self, model: str = "gpt-4o-mini") -> None:
        self._model = model
        self._client = None

    def _available(self) -> bool:
        """Whether the cheap model is reachable (see AnswerNormalizer)."""
        return bool(os.getenv("OPENAI_API_KEY")) or llm_factory.gateway() == llm_factory.OPENROUTER

    async def rewrite(self, question: str, answer: str) -> Optional[str]:
        """Return a bare declarative fact, or ``None`` to drop the seed."""
        if not self._available():
            return None
        if self._client is None:
            self._client = llm_factory.openai_client(async_=True)
        try:
            response = await self._client.chat.completions.create(
                model=llm_factory.resolve_model(self._model),
                messages=[
                    {
                        "role": "user",
                        "content": _REWRITE_PROMPT.format(question=question, answer=answer),
                    }
                ],
            )
            text = (response.choices[0].message.content or "").strip().strip('"').strip()
            return text or None
        except Exception:
            return None


class OpenTriviaDBSource:
    """Source fact seeds from Open Trivia Database.

    We don't copy questions — we extract the underlying facts and use them
    as seeds for original question generation.
    """

    BASE_URL = "https://opentdb.com/api.php"

    def __init__(self, rewriter: Optional[OpenTriviaFactRewriter] = None) -> None:
        # Dormant by default: with no rewriter, `_build_fact` falls through to
        # the byte-identical `_extract_fact` re-wrap (RC-1 stays present until
        # the rewriter is wired at Phase 6). When a rewriter is injected, every
        # emitted fact is a guarded, non-echoing declarative statement.
        self._rewriter = rewriter

    async def get_facts(self, count: int = 20, topics: Optional[list[str]] = None) -> list[Fact]:
        """Get fact seeds from Open Trivia DB."""
        facts: list[Fact] = []

        # Map requested topics to opentdb categories
        categories_to_query = self._map_topics_to_categories(topics)

        async with httpx.AsyncClient(timeout=10.0) as client:
            for cat_id, cat_name in categories_to_query:
                try:
                    params = {
                        "amount": min(10, count),
                        "category": cat_id,
                        "type": "multiple",
                    }
                    resp = await client.get(self.BASE_URL, params=params)
                    if resp.status_code != 200:
                        continue

                    data = resp.json()
                    if data.get("response_code") != 0:
                        continue

                    for item in data.get("results", []):
                        fact = await self._build_fact(item, cat_name)
                        if fact:
                            facts.append(fact)

                except Exception as e:
                    print(f"OpenTDB error (category {cat_id}): {e}")

        return facts[:count]

    async def _build_fact(self, item: dict, category_name: str) -> Optional[Fact]:
        """Build a Fact, applying the RC-1 rewrite+guard when a rewriter is set.

        Dormant path (no rewriter) returns `_extract_fact`'s byte-identical
        re-wrap. Active path replaces the text with a cheap-model declarative
        fact and drops the seed (returns ``None``) whenever the rewrite is
        unavailable, empty, or still echoes the question — so an active source
        never emits the re-wrap the guard is meant to eliminate.
        """
        base = self._extract_fact(item, category_name)
        if base is None or self._rewriter is None:
            return base

        question = html.unescape(item.get("question", ""))
        answer = html.unescape(item.get("correct_answer", ""))
        rewritten = await self._rewriter.rewrite(question, answer)
        if not rewritten or _fact_echoes_question(rewritten, question):
            return None
        base.text = rewritten
        return base

    def _extract_fact(self, item: dict, category_name: str) -> Optional[Fact]:
        """Extract the underlying fact from a trivia question (don't copy the question)."""
        question = html.unescape(item.get("question", ""))
        answer = html.unescape(item.get("correct_answer", ""))
        difficulty = item.get("difficulty", "medium")

        if not question or not answer:
            return None

        # Convert Q+A into a fact statement
        fact_text = f"The answer to '{question}' is {answer}."

        # Rate surprise based on difficulty
        surprise_map = {"easy": 3.0, "medium": 5.0, "hard": 7.0}

        return Fact(
            text=fact_text,
            source_url="https://opentdb.com",
            source_name="Open Trivia Database",
            topic=category_name,
            surprise_rating=surprise_map.get(difficulty, 5.0),
            tags=[difficulty],
        )

    def _map_topics_to_categories(self, topics: Optional[list[str]]) -> list[tuple[int, str]]:
        """Map topic names to opentdb category IDs."""
        if not topics:
            # Return a diverse mix
            return [(k, v) for k, v in CATEGORY_MAP.items()]

        result = []
        topics_lower = [t.lower() for t in topics]
        for cat_id, cat_name in CATEGORY_MAP.items():
            if cat_name.lower() in topics_lower:
                result.append((cat_id, cat_name))

        if not result:
            # Fallback to general
            result = [(9, "General")]

        return result
