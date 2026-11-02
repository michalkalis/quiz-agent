"""Fresh entertainment questions (#223.3): /sk/otazky/cerstve/ and /cs/otazky/cerstve/.

The weekly job (#202) adds new entertainment questions that the app favours for two weeks. This page shows
the newest of them. The committed page is built from src/topics/fresh.<lang>.json (a fallback snapshot);
the deploy workflow then runs `build.py --fresh-live`, which fetches the current list from the public API
and rewrites only these pages. If the API fails or returns too few questions, the fallback stays.
"""

from __future__ import annotations

import json
import re
import urllib.request
from datetime import date
from pathlib import Path

API = "https://api.trubbo.app/api/v1/public/fresh-questions"
SLUG = "cerstve"
LIMIT = 12
MIN = 3
DASH = re.compile(r"\s+[–—]\s+|\s+-\s+")


def answer(value) -> str:
    """Headline or first accepted answer; stored as plain text, a JSON string or a JSON list."""
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except ValueError:
            pass
    if isinstance(value, list):
        value = value[0]
    value = str(value).strip().strip('"')
    return value[:1].upper() + value[1:]  # shown on its own line, so it starts like a sentence


def story(text: str) -> str:
    """House rule for public text: no dashes as punctuation; number ranges keep a plain hyphen."""
    text = DASH.sub(", ", text.strip())
    return re.sub(r"(?<=\d)[–—](?=\d)", "-", text)


def item(qid: str, q: str, a: str, explanation: str, source: str) -> dict | None:
    """One publishable question in the page shape, or None when it breaks a public-text rule."""
    q, a = q.strip(), answer(a)
    if re.search(r"[–—]", q + a) or not (source or "").startswith("https://") or not (explanation or "").strip():
        return None
    return {"id": qid, "q": q, "a": a, "story": story(explanation), "source": source}


def snapshot(src: Path, lang: str) -> dict:
    return json.loads((src / "topics" / f"fresh.{lang}.json").read_text("utf-8"))


def live(lang: str) -> dict | None:
    """Current fresh questions from the API, or None (the build keeps the fallback)."""
    try:
        with urllib.request.urlopen(f"{API}?language={lang}&limit={LIMIT}", timeout=20) as response:
            rows = json.load(response)["questions"]
    except (OSError, ValueError, KeyError) as error:  # network, HTTP or JSON: never fail the deploy over this page
        print(f"fresh/{lang}: API unavailable ({error}), keeping the snapshot")
        return None
    items = [i for r in rows if (i := item(r["id"], r["question"], r["answer"], r["explanation"], r["source_url"]))]
    if len(items) < MIN:
        print(f"fresh/{lang}: only {len(items)} questions from the API, keeping the snapshot")
        return None
    return {"updated": date.today().isoformat(), "questions": items}


def updated(texts: dict, iso: str) -> str:
    d = date.fromisoformat(iso)
    return texts["fresh.updated"].format(date=f"{d.day}. {d.month}. {d.year}")
