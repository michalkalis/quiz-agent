"""Two-tier fact-check routing (#166 increment 3).

D21b measured where the web-grounded fact-check actually earns its ~18¢/q:
all 6 planted errors sat in the news-sourced arms, while the 70 direct-gen
evergreen questions were fully clean. Routing therefore skips the web
fact-check for evergreen questions and keeps it for fresh/news content.

The signal is deterministic and cheap (no LLM on the routing path):

1. **Provenance** — the question was generated from a web-sourced fact
   (``source_url`` / ``fact_ids``). Catches errors with no textual recency
   marker at all (D21b q48: a wrong producer credit phrased entirely in the
   past tense — only this branch routes it to the check).
2. **Fresh text markers** — a year within the last two years, recency
   phrasing, or record/superlative claims in the question/topic text.
   Protects direct-gen questions on fresh topics ("2026 movies"). On D21b
   this branch alone routes 5/6 errors and only 5/70 evergreen questions.

Validated on the D21b set 2026-08-24: combined routing sends 6/6 known
errors to the web check (recall preserved) and exempts 65/70 clean
evergreen questions (cost).

Founder decision 2026-08-25: stays dormant. The founder's manual
verification of all flagged questions added q95 — an evergreen error with
no textual marker — to the reference set, so "evergreen = clean" no longer
holds (69/70, not 70/70), and no cheap check reached the bar on q95's error
class (snippets don't surface it; only agentic page-reading does). Every
factual question therefore keeps the full web check; the cost lever is the
Batch API (-50%) for latency-insensitive corpus generation, not weaker
checking. Do not enable ``FACTCHECK_TIER_ROUTING`` without a new evergreen
policy validated on the founder reference set
(``factcheck_founder_verdicts_2026-08-25.json``).
"""

from __future__ import annotations

import datetime
import os
import re

from quiz_shared.models.question import Question

# How many calendar years back still counts as "fresh". A question naming a
# year in this window rides on facts that can shift under it (running
# totals, records, release dates); anything older is settled history.
_FRESH_YEAR_WINDOW = 2

_YEAR_RE = re.compile(r"\b(19\d{2}|20\d{2})\b")
_RECENCY_RE = re.compile(
    r"\b(most recent|latest|current(?:ly)?|newest|reigning|defending"
    r"|as of|to date|so far|recently|this (?:year|season|decade)|all[- ]time)\b",
    re.IGNORECASE,
)
# Record/superlative claims are the stale-prone class: true when written,
# overtaken later (D21b q03 "only song ever...twice", q18 "holds the record").
_SUPERLATIVE_RE = re.compile(
    r"\b(record|only .{0,40}\bever\b|first .{0,30}\b(?:to|ever)\b|holds?)\b",
    re.IGNORECASE,
)


def tier_routing_enabled() -> bool:
    """Opt-in while dormant: only ``FACTCHECK_TIER_ROUTING=1/true`` enables."""
    value = (os.getenv("FACTCHECK_TIER_ROUTING") or "").strip().lower()
    return value in {"1", "true", "yes", "on"}


def needs_web_factcheck(question: Question) -> bool:
    """True when the question routes to the full web-grounded fact-check."""
    if question.source_url:
        return True
    meta = question.generation_metadata
    if meta is not None and meta.fact_ids:
        return True
    return _has_fresh_markers(f"{question.question} {question.topic or ''}")


def _has_fresh_markers(text: str) -> bool:
    threshold = datetime.date.today().year - _FRESH_YEAR_WINDOW
    if any(int(year) >= threshold for year in _YEAR_RE.findall(text)):
        return True
    return bool(_RECENCY_RE.search(text) or _SUPERLATIVE_RE.search(text))
