"""News and trending topics source for time-sensitive quiz questions."""

from datetime import datetime, timedelta
from typing import Optional

import httpx

from .models import Fact


class NewsSource:
    """Source current events and trending topics for timely questions."""

    # Free RSS feeds for general news
    RSS_FEEDS = [
        ("BBC News", "https://feeds.bbci.co.uk/news/rss.xml"),
        ("Reuters", "https://www.rss-bridge.org/bridge01/?action=display&bridge=Reuters&feed=home%2Ftopnews&format=Atom"),
    ]

    async def get_facts(self, count: int = 10, topics: Optional[list[str]] = None) -> list[Fact]:
        """Get news-based facts.

        Returns facts with expiry dates (news becomes stale).
        """
        facts: list[Fact] = []

        async with httpx.AsyncClient(timeout=10.0, follow_redirects=True) as client:
            for feed_name, feed_url in self.RSS_FEEDS:
                try:
                    resp = await client.get(feed_url)
                    if resp.status_code != 200:
                        continue

                    feed_facts = self._parse_rss(resp.text, feed_name)
                    facts.extend(feed_facts)
                except Exception as e:
                    print(f"News source error ({feed_name}): {e}")

        return facts[:count]

    def _parse_rss(self, xml_text: str, source_name: str) -> list[Fact]:
        """Parse RSS XML into facts (simple regex-based parser)."""
        import re

        facts = []
        # Simple RSS item extraction
        items = re.findall(r"<item>(.*?)</item>", xml_text, re.DOTALL)
        if not items:
            # Try Atom format
            items = re.findall(r"<entry>(.*?)</entry>", xml_text, re.DOTALL)

        for item in items[:10]:
            title = re.search(r"<title[^>]*>(.*?)</title>", item, re.DOTALL)
            link = re.search(r"<link[^>]*>(.*?)</link>", item, re.DOTALL)
            if not link:
                link = re.search(r'<link[^>]*href="([^"]*)"', item)
            desc = re.search(r"<description[^>]*>(.*?)</description>", item, re.DOTALL)
            if not desc:
                desc = re.search(r"<summary[^>]*>(.*?)</summary>", item, re.DOTALL)

            if title:
                title_text = re.sub(r"<!\[CDATA\[(.*?)\]\]>", r"\1", title.group(1)).strip()
                title_text = re.sub(r"<[^>]+>", "", title_text)

                link_text = ""
                if link:
                    link_text = re.sub(r"<!\[CDATA\[(.*?)\]\]>", r"\1", link.group(1)).strip()
                    link_text = re.sub(r"<[^>]+>", "", link_text).strip()

                desc_text = ""
                if desc:
                    desc_text = re.sub(r"<!\[CDATA\[(.*?)\]\]>", r"\1", desc.group(1)).strip()
                    desc_text = re.sub(r"<[^>]+>", "", desc_text)[:300]

                fact_text = title_text
                if desc_text:
                    fact_text = f"{title_text}. {desc_text}"

                facts.append(Fact(
                    text=fact_text,
                    source_url=link_text if link_text else None,
                    source_name=source_name,
                    topic="Current Events",
                    surprise_rating=6.0,
                    expires_at=datetime.now() + timedelta(days=30),
                    tags=["news", "current-events"],
                ))

        return facts
