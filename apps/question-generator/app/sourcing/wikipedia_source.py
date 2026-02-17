"""Wikipedia fact sourcing — extracts interesting facts from Wikipedia APIs."""

import asyncio
import re
from typing import Optional

import httpx

from .models import Fact


class WikipediaSource:
    """Source interesting facts from Wikipedia."""

    BASE_URL = "https://{lang}.wikipedia.org/api/rest_v1"
    WIKI_API = "https://{lang}.wikipedia.org/w/api.php"

    def __init__(self, languages: Optional[list[str]] = None):
        self.languages = languages or ["en"]

    async def get_facts(self, count: int = 20, topics: Optional[list[str]] = None) -> list[Fact]:
        """Gather facts from multiple Wikipedia sources."""
        facts: list[Fact] = []

        async with httpx.AsyncClient(timeout=15.0) as client:
            # "Did you know..." facts from main page
            for lang in self.languages:
                dyk_facts = await self._get_did_you_know(client, lang)
                facts.extend(dyk_facts)

            # Featured article extracts
            for lang in self.languages:
                featured = await self._get_featured_article_facts(client, lang)
                facts.extend(featured)

            # Random articles from interesting categories
            if topics:
                for topic in topics[:5]:
                    topic_facts = await self._search_topic_facts(client, topic)
                    facts.extend(topic_facts)

        return facts[:count]

    async def _get_did_you_know(self, client: httpx.AsyncClient, lang: str = "en") -> list[Fact]:
        """Get 'Did you know...' facts from Wikipedia main page."""
        facts = []
        try:
            url = self.WIKI_API.format(lang=lang)
            params = {
                "action": "parse",
                "page": "Main_Page" if lang == "en" else self._main_page_name(lang),
                "prop": "text",
                "section": "0",
                "format": "json",
            }

            resp = await client.get(url, params=params)
            if resp.status_code != 200:
                return facts

            data = resp.json()
            html = data.get("parse", {}).get("text", {}).get("*", "")

            # Extract DYK items (they're in list items with "Did you know" patterns)
            dyk_pattern = re.compile(r"<li[^>]*>.*?</li>", re.DOTALL)
            items = dyk_pattern.findall(html)

            for item in items:
                # Strip HTML tags
                clean = re.sub(r"<[^>]+>", "", item).strip()
                if len(clean) > 30 and len(clean) < 500:
                    facts.append(Fact(
                        text=clean,
                        source_url=f"https://{lang}.wikipedia.org",
                        source_name=f"Wikipedia ({lang}) — Did you know",
                        topic="General",
                        surprise_rating=7.0,
                        language=lang,
                    ))
        except Exception as e:
            print(f"Wikipedia DYK error ({lang}): {e}")

        return facts[:10]

    async def _get_featured_article_facts(self, client: httpx.AsyncClient, lang: str = "en") -> list[Fact]:
        """Get interesting facts from today's featured article."""
        facts = []
        try:
            from datetime import date
            today = date.today()
            url = f"{self.BASE_URL.format(lang=lang)}/feed/featured/{today.year}/{today.month:02d}/{today.day:02d}"

            resp = await client.get(url)
            if resp.status_code != 200:
                return facts

            data = resp.json()

            # Extract from "tfa" (today's featured article)
            tfa = data.get("tfa", {})
            if tfa:
                extract = tfa.get("extract", "")
                title = tfa.get("titles", {}).get("normalized", "")
                page_url = tfa.get("content_urls", {}).get("desktop", {}).get("page", "")

                if extract and len(extract) > 50:
                    # Take first 2 sentences as a fact
                    sentences = extract.split(". ")
                    fact_text = ". ".join(sentences[:2]) + "."
                    facts.append(Fact(
                        text=fact_text,
                        source_url=page_url,
                        source_name=f"Wikipedia ({lang}) — Featured Article: {title}",
                        excerpt=extract[:300],
                        topic="General",
                        surprise_rating=6.0,
                        language=lang,
                    ))

            # Extract from "mostread" articles
            mostread = data.get("mostread", {}).get("articles", [])
            for article in mostread[:5]:
                extract = article.get("extract", "")
                title = article.get("titles", {}).get("normalized", "")
                page_url = article.get("content_urls", {}).get("desktop", {}).get("page", "")

                if extract and len(extract) > 50:
                    sentences = extract.split(". ")
                    fact_text = ". ".join(sentences[:2]) + "."
                    facts.append(Fact(
                        text=fact_text,
                        source_url=page_url,
                        source_name=f"Wikipedia ({lang}) — Trending: {title}",
                        excerpt=extract[:300],
                        topic="General",
                        surprise_rating=5.5,
                        language=lang,
                    ))

        except Exception as e:
            print(f"Wikipedia featured error ({lang}): {e}")

        return facts

    async def _search_topic_facts(self, client: httpx.AsyncClient, topic: str, lang: str = "en") -> list[Fact]:
        """Search Wikipedia for facts about a specific topic."""
        facts = []
        try:
            url = self.WIKI_API.format(lang=lang)
            params = {
                "action": "query",
                "list": "search",
                "srsearch": f"{topic} interesting fact",
                "srlimit": 5,
                "format": "json",
            }

            resp = await client.get(url, params=params)
            if resp.status_code != 200:
                return facts

            data = resp.json()
            results = data.get("query", {}).get("search", [])

            for result in results:
                snippet = re.sub(r"<[^>]+>", "", result.get("snippet", ""))
                title = result.get("title", "")

                if snippet and len(snippet) > 30:
                    facts.append(Fact(
                        text=f"{title}: {snippet}",
                        source_url=f"https://{lang}.wikipedia.org/wiki/{title.replace(' ', '_')}",
                        source_name=f"Wikipedia ({lang}) — {title}",
                        topic=topic,
                        surprise_rating=5.0,
                        language=lang,
                    ))
        except Exception as e:
            print(f"Wikipedia search error ({topic}): {e}")

        return facts

    @staticmethod
    def _main_page_name(lang: str) -> str:
        """Get main page name for different language Wikipedias."""
        names = {
            "en": "Main_Page",
            "sk": "Hlavná_stránka",
            "cs": "Hlavní_strana",
            "de": "Wikipedia:Hauptseite",
            "fr": "Wikipédia:Accueil_principal",
        }
        return names.get(lang, "Main_Page")
