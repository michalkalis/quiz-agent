"""Czech and Slovak quiz culture source — facts from SK/CZ Wikipedia and quiz traditions."""

from typing import Optional

from .wikipedia_source import WikipediaSource
from .models import Fact


class CzechSlovakSource:
    """Source facts from Slovak and Czech Wikipedia and quiz culture.

    Provides a different cultural angle to enrich question variety.
    Sources:
    - Slovak Wikipedia "Vedeli ste, ze..." (Did you know...)
    - Czech Wikipedia "Vite, ze..." (Did you know...)
    - Regional interesting facts
    """

    def __init__(self):
        self.wiki_source = WikipediaSource(languages=["sk", "cs"])

    async def get_facts(self, count: int = 10, topics: Optional[list[str]] = None) -> list[Fact]:
        """Get facts from Czech and Slovak sources."""
        facts = await self.wiki_source.get_facts(count=count, topics=topics)

        # Tag all facts with their cultural origin
        for fact in facts:
            if "sk" in fact.source_name.lower():
                fact.tags.append("slovak-culture")
            elif "cs" in fact.source_name.lower():
                fact.tags.append("czech-culture")

        return facts[:count]
