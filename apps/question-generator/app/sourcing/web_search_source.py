"""Web search fact sourcing — finds interesting facts via web search."""

from typing import Optional

from .models import Fact


class WebSearchSource:
    """Source facts via web search APIs.

    This is a placeholder that can be connected to various search APIs
    (Google Custom Search, Bing, Brave Search, etc.)
    """

    async def get_facts(self, count: int = 10, topics: Optional[list[str]] = None) -> list[Fact]:
        """Get facts via web search.

        Currently returns empty list — implement with your preferred search API.
        Suggested search queries:
        - "surprising facts about {topic}"
        - "things most people don't know about {topic}"
        - "interesting {topic} trivia"
        """
        # TODO: Implement with a search API (Google Custom Search, Brave, etc.)
        # For now, this is a placeholder that can be connected later
        return []
