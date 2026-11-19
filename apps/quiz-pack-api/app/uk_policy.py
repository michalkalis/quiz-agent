"""Ukrainian-only content rules (#231 — Ukrainian as a fourth language, 231.2).

Deterministic checks, free and pure so every gate can call them:

* Russian contamination: Ukrainian and Russian share most of the Cyrillic
  alphabet, so the tells are the letters Ukrainian does not have (ы э ъ ё),
  spellings Ukrainian never uses ("ии", "ье", a past tense in "-лся"),
  Russian-only and surzhyk words, Russian forms of place names ("Киев",
  "Харьков") and a long text with none of і ї є ґ. A model that slips into
  Russian (or into the surzhyk mix) trips this before a human reads the row.
* Topic policy (founder 2026-11-08): history, culture and sport are fine; the
  war since 2014, current politics and relations with Russia are out entirely,
  even as heroic stories. Keyword lists, sorted into three tiers:

  - **clean**: no hit. Plain words that only look like a hit stay here: роса
    (dew, "на росі"), the river Рось ("на Росі"), "агресія у тварин".
  - **hold**: a word that may or may not be about the excluded topics: Russia
    and Moscow (the Russian Empire is history), war, invasion, occupation and
    annexation (the Mongols in 1240, Kyiv in 1941, Crimea in 1783), Crimea and
    Donbas, politics words, and any year from 2014 on. The row is never
    machine-approved (``machine_approval``: stays pending_review, so
    TestFlight-only) and a human decides. Never dropped.
  - **reject**: wording with no reading before 2014: the full-scale invasion,
    Azovstal, the Revolution of Dignity, "РФ", Putin…, or a war word or place
    together with a year from 2014 on in the same sentence ("Донбас … 2022").
    Such a seed is dropped (counted) and such a row never enters the corpus
    (importer). Any other hold word next to a recent year only holds: a wrong
    reject silently loses a good question, a hold costs one human look.

  Reasons quote the matched words so the reviewer sees why at a glance.
* Source: a Russian state or ``.ru`` source holds the row for a human.

Scoped to ``uk`` on purpose: for en/sk/cs the standing rule stays "avoid
CURRENT politics and wars" (``corpus/fresh_brief.ANCHOR``).
"""

from __future__ import annotations

import re
from collections.abc import Iterable
from urllib.parse import urlsplit

UK = "uk"

_RUSSIAN_ONLY_LETTERS = frozenset("ыэъёЫЭЪЁ")

# Everyday words that are Russian (or surzhyk) and not Ukrainian (uk: що, це,
# як, або, лише, дуже, якщо, коли, теж, щоб, був, який, році, народився, жив,
# місті, столиця, вона, де, зараз, звичайно). Whole-word, casefolded; words
# Ukrainian shares ("и", "не", "он", "город" = garden, "жила" = vein, "жили",
# "родилась") stay out so a Ukrainian
# text never trips on them. Russian place-name forms sit here too ("Львов",
# but not "Львова", which is also the Ukrainian genitive).
_RUSSIAN_ONLY_WORDS = frozenset(
    """что это как или только очень если когда тоже чтобы был была было были
    который которая которое которые также после между какой какая какое какие
    каком какого какую году родился городе
    столица столице столицей она они его где здесь сейчас почему сколько всего
    нет самый самая самое самые является являются называется сегодня вообще
    конечно ладно шо канєшно конєшно конешно тіпа типа щас всьо нада
    кто чем чей лучший лучшая впервые время страна стране страну
    написал создал открыл основал сказал стал получил построил назвал спел
    львов львове ровно кривой сергей сергея сергею сергеем андрей андрея
    андрею андреем""".split()
)
# Word starts that are Russian forms of names and loanwords (uk: Київ, Харків,
# Одеса, Дніпро, Запоріжжя, Борщів, меланін, Володимир, Микола / Миколаїв,
# Чернігів, Донецьк, Дністер).
_RUSSIAN_STEMS = (
    "киев",
    "харьков",
    "одесс",
    "днепр",
    "запорожж",
    "борщев",
    "меланин",
    "владимир",
    "никола",
    "чернигов",
    "донецк",
    "днестр",
)
# Spellings Ukrainian never uses: "ии" (Франции), "ье" (Запорожье), and the
# masculine reflexive past in "-лся" (uk "-вся": родился / народився).
_RUSSIAN_SPELLING_RE = re.compile(r"ии|ье|лся\b")
# "Вена" is Vienna in Russian (uk "Відень") but also a vein in both: only the
# capitalised city form counts.
_RUSSIAN_CASED_RE = re.compile(r"(?<![^\W\d_])Вен(?:а|е|у|ой)\b")
_UK_ONLY_LETTERS = frozenset("іїєґ")
# A Ukrainian text this long without one of і ї є ґ is almost surely Russian
# (a real 65-letter sentence without them exists: "Перший пасажирський потяг
# прибув з Перемишля до Львова…", so the bar is well above it).
_NO_UK_LETTERS_MIN = 80
_WORD_RE = re.compile(r"[^\W\d_]+", re.UNICODE)


def _is_cyrillic(ch: str) -> bool:
    return "Ѐ" <= ch <= "ӿ"


def russian_contamination_reason(texts: Iterable[str]) -> str | None:
    """A reason string when any text reads as Russian rather than Ukrainian.

    An authentic historical quote with ъ/ы (Anna of Kyiv signed «АНА РЪИНА»)
    is held too. That is fine: a human approves it, the gate does not guess.
    """
    letters: set[str] = set()
    words: set[str] = set()
    long_without_uk = False
    for text in map(str, texts):
        letters |= {ch for ch in text if ch in _RUSSIAN_ONLY_LETTERS}
        for word in (m.casefold() for m in _WORD_RE.findall(text)):
            if (
                word in _RUSSIAN_ONLY_WORDS
                or word.startswith(_RUSSIAN_STEMS)
                or _RUSSIAN_SPELLING_RE.search(word)
            ):
                words.add(word)
        words |= {m.casefold() for m in _RUSSIAN_CASED_RE.findall(text)}
        cyrillic = [ch for ch in text.casefold() if _is_cyrillic(ch)]
        if len(cyrillic) >= _NO_UK_LETTERS_MIN and not _UK_ONLY_LETTERS & set(cyrillic):
            long_without_uk = True
    if letters:
        return f"russian_letters({''.join(sorted(letters))})"
    if words:
        return f"russian_words({','.join(sorted(words))})"
    if long_without_uk:
        return "russian_text(no і/ї/є/ґ)"
    return None


# Regexes over casefolded text, each anchored at a word start (see
# ``_matches``). Reject: no reading before 2014.
_REJECT = (
    # "повномасштабна реставрація" is a restoration; only the invasion counts
    # (bare "з початку повномасштабного" is the invasion too, so it holds).
    r"повномасштабн\w* (?:вторгн|війн|наступ)\w*",
    r"азовстал\w*",
    r"революці\w* гідності",
    r"євромайдан\w*",
    r"небесн\w* сотн\w*",
    r"зсу\b",  # whole word only: "зсув" is a landslide
    r"рф\b",
    r"[дл]нр\b",
    r"рашист\w*",
    r"путін\w*",
    r"мінськ\w* угод\w*",
)
# Hold, war and its places: a recent year in the SAME sentence makes these a
# reject ("Донбас … 2022"). "війна" and "облога" are not here: history rows
# use them next to a recent year ("фільм про Другу світову війну 2019 року",
# "200-річчя Шевченка 2014 … після війни"), so those only hold.
_HOLD_WAR = (
    r"вторгнен\w*",
    r"окупа\w*",
    r"окупов\w*",
    r"анексі\w*",
    r"агресор\w*",
    r"мобілізац\w*",
    r"фронт(?:і|у|ом|ах|ів|и)?\b",
    r"24 лютого",
    r"крим(?:у|і|ом|ськ\w*)?\b",
    r"донбас\w*",
    r"гостомел\w*",
    r"бахмут\w*",
    r"ірпін\w*",
    r"буч(?:а|і|у|ею)\b",
    r"авдіївк\w*",
    r"маріупол\w*",
    r"зміїн\w*",
)
# Hold: may be history before 2014 or may not; a human decides.
_HOLD = _HOLD_WAR + (
    # Russia and Moscow. "росі" alone is dew or the river Рось: not listed.
    r"росі[яїює]\w*",
    r"російськ\w*",
    r"росіян\w*",
    r"москв\w*",
    r"москал\w*",
    r"кремл\w*",
    # war, siege, fighting and its symbols since 2014
    r"повномасштабн\w*",
    r"війн\w*",
    r"воєнн\w*",
    r"облог\w*",
    r"бо(?:ї|їв|ях|ями|ям)\b",
    r"бойов\w*",
    r"збройн\w* сил\w*",
    r"кіборг\w*",
    r"ато\b",  # whole word only: "атом"
    r"байрактар\w*",
    r"джавелін\w*",
    r"хаймарс\w*",
    r"прикордонник\w*",
    r"звільн\w*",  # "звільнили навесні": a liberated town
    # politics
    r"президент\w*",
    r"прем['’ʼ]?єр(?:-міністр\w*)?\b",  # not "прем'єра", a premiere
    r"міністр\w*",
    r"уряд\w*",
    r"мер(?:а|ом|у|и|ів|ам|ами|ах)?\b",  # a mayor; not "Мері" (Mary)
    r"мері[яїює]\w*",
    r"нато\b",
    r"верховн\w* рад\w*",
    r"парламент\w*",
    r"депутат\w*",
    r"вибор(?:и|ів|ах|ами|ам)\b",
    r"виборч\w*",
    r"санкці\w*",
    r"зеленськ\w*",
    r"порошенк\w*",
    r"янукович\w*",
    r"тимошенк\w*",
    r"залужн\w*",
    r"буданов\w*",
)
_RECENT_YEAR_RE = re.compile(r"(?<!\d)20(?:1[4-9]|[2-9]\d)(?!\d)")
_WORD_START = r"(?<![^\W\d_])"
_REJECT_RE = re.compile(_WORD_START + "(?:" + "|".join(_REJECT) + ")")
_HOLD_RE = re.compile(_WORD_START + "(?:" + "|".join(_HOLD) + ")")
_HOLD_WAR_RE = re.compile(_WORD_START + "(?:" + "|".join(_HOLD_WAR) + ")")
# Sentence ends, but not after a one-letter abbreviation ("2015 р. бої").
_SENTENCE_END_RE = re.compile(r"(?<=[.!?…])(?<!\b\w\.)\s+")

REJECT_PREFIX = "topic_policy:reject"
HOLD_PREFIX = "topic_policy:hold"

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
    """``topic_policy:reject(…)`` / ``topic_policy:hold(…)`` naming the
    matched words, or ``None`` when the texts are clean (tiers: module doc)."""
    folded = [str(t).casefold() for t in texts]
    rejects = {m for t in folded for m in _REJECT_RE.findall(t)}
    holds = {m for t in folded for m in _HOLD_RE.findall(t)}
    years = {m for t in folded for m in _RECENT_YEAR_RE.findall(t)}
    for sentence in (s for t in folded for s in _SENTENCE_END_RE.split(t)):
        war = _HOLD_WAR_RE.findall(sentence)
        recent = _RECENT_YEAR_RE.findall(sentence)
        if war and recent:
            rejects |= set(war) | set(recent)
    if rejects:
        return f"{REJECT_PREFIX}({', '.join(sorted(rejects | holds | years))})"
    if holds or years:
        return f"{HOLD_PREFIX}({', '.join(sorted(holds | years))})"
    return None


def topic_reject_reason(texts: Iterable[str]) -> str | None:
    """The reject tier only (a hold is a human's call, not a drop)."""
    reason = topic_policy_reason(texts)
    return reason if reason and reason.startswith(REJECT_PREFIX) else None


# Russian state outlets on non-.ru domains (TASS, Russia Beyond, RT, Channel
# One, VGTRK) and Russian portals.
_SOURCE_DENY_DOMAINS = (
    "mail.ru",
    "gw2ru.com",
    "rt.com",
    "tass.com",
    "rbth.com",
    "1tv.com",
    "russia.tv",
)
_SOURCE_DENY_TLDS = (".ru", ".su", ".рф", ".xn--p1ai")
# A Russian-language or Russia-locale page on any site: "/ru/", "/en-ru/",
# "/ru-ru/".
_RU_PATH_SEGMENT_RE = re.compile(r"(?i)^(?:[a-z]{2}[-_])?ru$")
# A URL wrapped inside another one (web.archive.org/web/2020/https://lenta.ru).
_EMBEDDED_URL_RE = re.compile(r"(?i)https?:/+(.+)")
_ARCHIVE_PATH_RE = re.compile(r"^/web/[^/]+/(.+)")


def source_reason(url: str | None) -> str | None:
    """A reason when the source is Russian (``.ru``, ``ru.wikipedia``, RT,
    TASS, Sputnik, a Russia-locale path, or an archive of a Russian URL)."""
    url = (url or "").strip()
    parts = urlsplit(url if "//" in url else "//" + url)
    host = parts.hostname or ""
    if not host:
        return None
    if (
        host.endswith(_SOURCE_DENY_TLDS)
        or "ru" in host.split(".")
        or any(host == d or host.endswith("." + d) for d in _SOURCE_DENY_DOMAINS)
        or "sputnik" in host
        or any(_RU_PATH_SEGMENT_RE.match(seg) for seg in parts.path.split("/"))
    ):
        return f"russian_source({host})"
    rest = parts.path + ("?" + parts.query if parts.query else "")
    inner = _EMBEDDED_URL_RE.search(rest)
    if inner is None and host.endswith("archive.org"):
        inner = _ARCHIVE_PATH_RE.match(parts.path)
    return source_reason(inner.group(1)) if inner else None
