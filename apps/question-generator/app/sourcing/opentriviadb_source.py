"""Open Trivia Database source — extracts underlying facts from trivia questions."""

import html
from typing import Optional

import httpx

from .models import Fact


# Map opentdb category IDs to topic names
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
}


class OpenTriviaDBSource:
    """Source fact seeds from Open Trivia Database.

    We don't copy questions — we extract the underlying facts and use them
    as seeds for original question generation.
    """

    BASE_URL = "https://opentdb.com/api.php"

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
                        fact = self._extract_fact(item, cat_name)
                        if fact:
                            facts.append(fact)

                except Exception as e:
                    print(f"OpenTDB error (category {cat_id}): {e}")

        return facts[:count]

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
