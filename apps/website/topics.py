"""Question topic pages (#223): /sk/otazky/<slug>/, /cs/otazky/<slug>/ and a hub at /<lang>/otazky/.

Texts: src/topics/<lang>.json. Questions: src/topics/questions.<lang>.json, a snapshot of approved,
sourced questions from production made by tools/topic_snapshot.py. Topics pair up across languages by
their `key`, which drives hreflang. Pages need no script: the answer sits in <details>, so it is in the
HTML for search engines and opens on tap without JavaScript.
"""

from __future__ import annotations

import html
import json
import re
from pathlib import Path

LANGS = {"sk": "/sk/", "cs": "/cs/"}
DIR = "otazky"
COLORS = ["blue", "orange", "green", "purple", "yellow", "rose"]
PT = "119419107"  # App Store Connect provider token for campaign links (ct=web_<lang>_<slug>)


def load(src: Path, lang: str) -> tuple[dict, dict]:
    texts = json.loads((src / "topics" / f"{lang}.json").read_text("utf-8"))
    questions = json.loads((src / "topics" / f"questions.{lang}.json").read_text("utf-8"))
    return texts, questions


def lint(src: Path, dash: re.Pattern, tag: re.Pattern) -> list[str]:
    """Same public-text rules as the main page, applied to topic texts and every published question."""
    errors = []
    keys = {}
    for lang in LANGS:
        texts, questions = load(src, lang)
        keys[lang] = [t["key"] for t in texts["topics"]]
        values = [v for k, v in texts.items() if k != "topics"]
        values += [t[f] for t in texts["topics"] for f in ("about", "lead")]
        for t in texts["topics"]:
            items = questions.get(t["slug"], [])
            if len(items) < 10:
                errors.append(f"topics/{lang}: {t['slug']} has {len(items)} questions (min 10)")
            values += [q[f] for q in items for f in ("q", "a", "story")]
            if any(not q["source"].startswith("https://") for q in items):
                errors.append(f"topics/{lang}: {t['slug']} has a question without an https source")
        errors += [f"topics/{lang}: dash used as punctuation: {v[:80]!r}" for v in values if dash.search(tag.sub("", v))]
        ids = [q["id"] for items in questions.values() for q in items]
        if len(ids) != len(set(ids)):
            errors.append(f"topics/{lang}: a question appears on more than one page")
    if len({tuple(k) for k in keys.values()}) != 1:
        errors.append("topics: sk and cs must list the same topic keys in the same order")
    return errors


def store(lang: str, base: str, campaign: str) -> str:
    return f"{base}?pt={PT}&ct=web_{lang}_{campaign}&mt=8"


def title(texts: dict, about: str) -> str:
    return f"{texts['title.prefix']} {about} {texts['title.suffix']}"


def heading(texts: dict, about: str) -> str:
    return f"{texts['title.prefix']} {about}"


def esc(value: str) -> str:
    return html.escape(value, quote=True)


def source_label(url: str) -> str:
    host = re.sub(r"^https://(www\.)?", "", url).split("/")[0]
    return host


def cards(lang: str, texts: dict, questions: dict, skip: str = "") -> str:
    out = []
    for i, t in enumerate(texts["topics"]):
        if t["slug"] == skip:
            continue
        first = questions[t["slug"]][0]["q"]
        out.append(
            f'<li><a class="topic c-{COLORS[i % len(COLORS)]}" href="{LANGS[lang]}{DIR}/{t["slug"]}/">'
            f'<span class="t">{esc(t["about"][:1].upper() + t["about"][1:])}</span>'
            f'<span class="n">{esc(texts["count"].format(n=len(questions[t["slug"]])))}</span>'
            f'<span class="ex">{esc(first)}</span></a></li>'
        )
    return '<ul class="topics">' + "".join(out) + "</ul>"


def cta(lang: str, texts: dict, link: str) -> str:
    return (
        '<section class="cta"><div>'
        f'<h2 class="disp">{esc(texts["cta.title"])}</h2><p>{esc(texts["cta.body"])}</p></div>'
        f'<div class="ctas"><a class="store" href="{esc(link)}"><img src="/app-store-badge.svg" width="156" height="52" '
        f'alt="{esc(texts["cta.store"])}"></a><span class="note">{esc(texts["cta.note"])}</span></div></section>'
    )


def topic_main(lang: str, texts: dict, questions: dict, i: int, link: str) -> str:
    t = texts["topics"][i]
    items = questions[t["slug"]]
    color = COLORS[i % len(COLORS)]
    qs = "".join(
        f'<li class="qa"><p class="q">{esc(q["q"])}</p><details><summary>{esc(texts["reveal"])}</summary>'
        f'<p class="a">{esc(q["a"])}</p><p class="story">{esc(q["story"])}</p>'
        f'<a class="src" href="{esc(q["source"])}" rel="nofollow noopener">{esc(texts["source"])}: {esc(source_label(q["source"]))}</a>'
        f"</details></li>"
        for q in items
    )
    return (
        f'<nav class="crumb"><a href="{LANGS[lang]}{DIR}/">{esc(texts["title.prefix"])}</a></nav>'
        f'<section class="head c-{color}"><h1 class="disp">{esc(heading(texts, t["about"]))}</h1>'
        f'<p class="lead">{esc(t["lead"])}</p>'
        f'<p class="how">{esc(texts["count"].format(n=len(items)))}. {esc(texts["how"])}</p></section>'
        f'<ol class="qs c-{color}">{qs}</ol>'
        + cta(lang, texts, link)
        + f'<section class="more"><h2 class="disp">{esc(texts["more"])}</h2>{cards(lang, texts, questions, t["slug"])}</section>'
    )


def hub_main(lang: str, texts: dict, questions: dict, link: str) -> str:
    return (
        f'<section class="head"><h1 class="disp">{esc(texts["title.prefix"] + " " + texts["title.suffix"])}</h1>'
        f'<p class="lead">{esc(texts["hub.lead"])}</p></section>'
        + cards(lang, texts, questions)
        + cta(lang, texts, link)
    )


def quiz_ld(lang: str, url: str, name: str, items: list) -> str:
    data = {
        "@context": "https://schema.org", "@type": "Quiz", "name": name, "url": url, "inLanguage": lang,
        "publisher": {"@id": "https://trubbo.app/#org"},
        "hasPart": [
            {"@type": "Question", "name": q["q"], "eduQuestionType": "Flashcard",
             "acceptedAnswer": {"@type": "Answer", "text": q["a"]}}
            for q in items
        ],
    }
    return json.dumps(data, ensure_ascii=False).replace("</", "<\\/")


def pages(src: Path, site: str, store_urls: dict) -> list[dict]:
    """Every topic and hub page as {lang, path, title, description, main, jsonld, alternates, short_link}."""
    data = {lang: load(src, lang) for lang in LANGS}
    out = []
    for lang, (texts, questions) in data.items():
        hub_path = f"{LANGS[lang]}{DIR}/"
        hub_alt = {other: f"{LANGS[other]}{DIR}/" for other in LANGS}
        link = store(lang, store_urls[lang], "otazky")
        out.append({
            "lang": lang, "path": hub_path, "texts": texts, "alternates": hub_alt,
            "title": f"{texts['title.prefix']} {texts['title.suffix']} | Trubbo",
            "description": texts["hub.description"], "main": hub_main(lang, texts, questions, link),
            "jsonld": "", "link": link,
        })
        for i, t in enumerate(texts["topics"]):
            path = f"{hub_path}{t['slug']}/"
            alt = {}
            for other, (o_texts, _) in data.items():
                match = next(o for o in o_texts["topics"] if o["key"] == t["key"])
                alt[other] = f"{LANGS[other]}{DIR}/{match['slug']}/"
            items = questions[t["slug"]]
            link = store(lang, store_urls[lang], t["slug"])
            out.append({
                "lang": lang, "path": path, "texts": texts, "alternates": alt,
                "title": f"{title(texts, t['about'])} | Trubbo",
                "description": texts["description"].format(n=len(items), about=t["about"]),
                "main": topic_main(lang, texts, questions, i, link),
                "jsonld": quiz_ld(lang, site + path, heading(texts, t["about"]), items), "link": link,
            })
    return out
