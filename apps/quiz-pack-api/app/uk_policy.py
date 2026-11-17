"""Ukrainian-only content rules (#231 — Ukrainian as a fourth language, 231.2).

Two deterministic checks, both free and pure so every gate can call them:

* Russian contamination: Ukrainian and Russian share most of the Cyrillic
  alphabet, so the cheap tell is the letters Ukrainian does not have (ы э ъ ё)
  plus a short list of everyday words that exist only in Russian. A model that
  slips into Russian (or into the "surzhyk" mix) trips this before a human
  ever has to read the row.
* Topic policy (founder 2026-11-08): history, culture and sport are fine; the
  war since 2014, current politics and relations with Russia are out entirely,
  even as heroic stories. The check is a deliberately blunt keyword stem list:
  it errs toward holding a row for a human (machine approval) or dropping a
  seed (weekly fresh run), never toward letting one through.

Scoped to ``uk`` on purpose: for en/sk/cs the standing rule stays "avoid
CURRENT politics and wars" (``corpus/fresh_brief.ANCHOR``).
"""

from __future__ import annotations

import re
from collections.abc import Iterable

UK = "uk"

_RUSSIAN_ONLY_LETTERS = frozenset("ыэъёЫЭЪЁ")

# Everyday words that are Russian and not Ukrainian (uk: що, це, як, або,
# лише, дуже, якщо, коли, теж, щоб, був). Whole-word, casefolded; "и" / "не"
# style shared words stay out so a Ukrainian text never trips on them.
_RUSSIAN_ONLY_WORDS = frozenset(
    {
        "что",
        "это",
        "как",
        "или",
        "только",
        "очень",
        "если",
        "когда",
        "тоже",
        "чтобы",
        "был",
        "была",
        "было",
        "были",
        "который",
        "которая",
        "которое",
        "которые",
        "также",
        "после",
        "между",
    }
)
_WORD_RE = re.compile(r"[^\W\d_]+", re.UNICODE)


def russian_contamination_reason(texts: Iterable[str]) -> str | None:
    """A reason string when any text carries Russian-only letters or words."""
    letters: set[str] = set()
    words: set[str] = set()
    for text in texts:
        letters |= {ch for ch in str(text) if ch in _RUSSIAN_ONLY_LETTERS}
        words |= {
            w
            for w in (m.casefold() for m in _WORD_RE.findall(str(text)))
            if w in _RUSSIAN_ONLY_WORDS
        }
    if letters:
        return f"russian_letters({''.join(sorted(letters))})"
    if words:
        return f"russian_words({','.join(sorted(words))})"
    return None


# Stems, matched at the start of a casefolded word. Russia and anything
# Russian, the invasion/occupation vocabulary, and the 2013-14 lead-up.
_TOPIC_STEMS = (
    "росі",
    "російськ",
    "росіян",
    "кремл",
    "путін",
    "москал",
    "вторгнен",
    "окупац",
    "окупант",
    "окупов",
    "анексі",
    "повномасштабн",
    "агресі",
    "євромайдан",
    "революці[яюї] гідності",
    "небесна сотня",
    "зсу\\b",  # whole word only: "зсув" is a landslide
)

UK_TOPIC_POLICY = (
    "TOPIC POLICY (Ukrainian pack): history, culture, science, nature, food "
    "and sport are welcome. Do NOT write questions about the war since 2014 "
    "(invasion, occupation, annexation, front-line events, wartime "
    "heroes or stories, even heroic ones), about current politics (politicians "
    "in office, elections, parties, laws in force), or about relations with "
    "Russia, and do not use Russia as a topic or as the answer. If a seed or a "
    "request points there, pick a different fact."
)

# The same rule in Ukrainian, for the native house-style file's checklist.
UK_TOPIC_POLICY_LINE = (
    "Війна з 2014 року, чинна політика та стосунки з Росією: цих тем немає "
    "взагалі, навіть як героїчних історій."
)


def topic_policy_reason(texts: Iterable[str]) -> str | None:
    """A reason string when any text touches an excluded Ukrainian topic."""
    hits: set[str] = set()
    for text in texts:
        folded = str(text).casefold()
        for stem in _TOPIC_STEMS:
            if re.search(r"(?<![^\W\d_])" + stem, folded):
                hits.add(stem.replace("\\b", ""))
    return f"topic_policy({','.join(sorted(hits))})" if hits else None
