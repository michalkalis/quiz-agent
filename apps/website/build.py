#!/usr/bin/env python3
"""Generate the static trubbo.app site from src/ into public/ (what GitHub Pages serves).

Inputs: src/template.html, src/screen.html (the phone screen partial), src/footer.html,
src/strings/<lang>.json, and the legal pages src/legal.html + src/legal/<page>.<lang>.html.
Stdlib only. Run from anywhere: python3 apps/website/build.py
Fails loudly on a missing, unused or untranslated key and on a dash used as punctuation.
"""

import html
import json
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
OUT = ROOT / "public"
SITE = "https://trubbo.app"
LANGS = {"en": "/", "sk": "/sk/", "cs": "/cs/"}  # en is the default at the root
LEGAL = ["privacy", "terms", "support"]  # served at /<page> (en), /sk/<page>, /cs/<page>
# Official social accounts: the English ones on /, the shared Slovak and Czech ones on /sk/ and /cs/.
SOCIAL_EN = {
    "Instagram": "https://www.instagram.com/trubboapp/",
    "YouTube": "https://www.youtube.com/@trubboapp",
    "TikTok": "https://www.tiktok.com/@trubboapp",
    "Facebook": "https://www.facebook.com/1454787731043491",
}
SOCIAL_SKCZ = {
    "Instagram": "https://www.instagram.com/trubboapp.sk/",
    "YouTube": "https://www.youtube.com/@trubboapp_sk",
    "Facebook": "https://www.facebook.com/1447421928452448",
}
SOCIAL = {"en": SOCIAL_EN, "sk": SOCIAL_SKCZ, "cs": SOCIAL_SKCZ}
STEPS = 6  # story steps; each has a static copy of the screen for the stacked fallback
STATIC = ["rethink-sans-latin.woff2", "rethink-sans-latin-ext.woff2", "rethink-sans-OFL.txt", "favicon.svg", "favicon.png", "apple-touch-icon.png", "mascot.svg", "mail-logo.png", "og.png", "robots.txt", "404.html", "CNAME", "join.html", ".well-known/apple-app-site-association"]

KEY = re.compile(r"\{\{\s*([a-z0-9_.]+)\s*\}\}")
DASH = re.compile(r"[–—]| - | -$|^- ")
TAG = re.compile(r"<[^>]+>")


def load(lang: str) -> dict:
    return json.loads((SRC / "strings" / f"{lang}.json").read_text("utf-8"))


def lint(lang: str, strings: dict, base: set) -> list:
    errors = []
    if set(strings) != base:
        errors.append(f"{lang}: keys differ from en: {sorted(set(strings) ^ base)}")
    for key, value in strings.items():
        if DASH.search(TAG.sub("", value)):
            errors.append(f"{lang}:{key}: dash used as punctuation: {value!r}")
    return errors


def screen(step: int, live: bool) -> str:
    """The phone screen at a given story step. The live one is sticky and switched by JS."""
    part = (SRC / "screen.html").read_text("utf-8")
    attrs = 'id="screen" ' if live else ""
    cls = "screen" if live else "screen mini-screen"
    return part.replace("{{gen.screen.attrs}}", f'{attrs}class="{cls}" data-step="{step}"')


def alternates(page: str = "") -> str:
    return "\n".join(
        f'<link rel="alternate" hreflang="{code}" href="{SITE + path + page}">' for code, path in LANGS.items()
    ) + f'\n<link rel="alternate" hreflang="x-default" href="{SITE}/{page}">'


def switcher(lang: str, page: str = "") -> str:
    return "".join(
        f'<a href="{path + page}" hreflang="{code}" lang="{code}"'
        + (' aria-current="page"' if code == lang else "")
        + f">{code.upper()}</a>"
        for code, path in LANGS.items()
    )


def footer(lang: str) -> str:
    """Footer partial with links to the legal pages and social accounts in the same language; its text keys stay for pass 2."""
    social = "".join(f'<a href="{url}" rel="me noopener">{name}</a>' for name, url in SOCIAL[lang].items())
    part = (SRC / "footer.html").read_text("utf-8").strip()
    return part.replace("{{gen.home}}", LANGS[lang]).replace("{{gen.social}}", social)


def jsonld(lang: str, strings: dict) -> str:
    """Structured data for search engines and AI answers: the publisher, the site and the app itself."""
    accounts = sorted({url for links in SOCIAL.values() for url in links.values()})
    org = {"@type": "Organization", "@id": SITE + "/#org", "name": "missinghue s.r.o.", "url": SITE + "/",
           "email": "hi@trubbo.app", "sameAs": accounts}
    site = {"@type": "WebSite", "@id": SITE + "/#site", "name": "Trubbo", "url": SITE + "/",
            "inLanguage": list(LANGS), "publisher": {"@id": SITE + "/#org"}}
    app = {"@type": "MobileApplication", "@id": SITE + "/#app", "name": "Trubbo", "url": SITE + LANGS[lang],
           "description": strings["meta.description"], "operatingSystem": "iOS",
           "applicationCategory": "GameApplication", "inLanguage": list(LANGS), "image": SITE + "/og.png",
           "offers": {"@type": "Offer", "price": "0", "priceCurrency": "EUR"},
           "publisher": {"@id": SITE + "/#org"}, "sameAs": accounts}
    data = {"@context": "https://schema.org", "@graph": [org, site, app]}
    return json.dumps(data, ensure_ascii=False).replace("</", "<\\/")


def sitemap() -> str:
    """Every indexable page with its language alternates, so all three languages get crawled."""
    pages = [""] + LEGAL
    urls = []
    for page in pages:
        links = "".join(f'<xhtml:link rel="alternate" hreflang="{c}" href="{SITE + p + page}"/>' for c, p in LANGS.items())
        urls += [f"<url><loc>{SITE + path + page}</loc>{links}</url>" for path in LANGS.values()]
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">\n'
            + "\n".join(urls) + "\n</urlset>\n")


def llms(strings: dict) -> str:
    """/llms.txt: a plain summary for AI assistants, built from the English page so it never drifts from it."""
    s = strings["en"]
    social = "\n".join(f"- {name}: {url}" for name, url in SOCIAL_EN.items())
    social += "\n" + "\n".join(f"- {name} (Slovak and Czech): {url}" for name, url in SOCIAL_SKCZ.items())
    return f"""# Trubbo

> {s["meta.description"]}

Trubbo reads each question aloud and the player answers in their own words; the app checks the answer and tells the story behind it. People play it alone or together: on road trips, at parties, at the cabin, with family.

## Pricing

- {s["price.free"]}: {s["price.free.d"]}
- {s["price.sub"]}: {s["price.sub.d"]}
- {s["price.packs"]}: {s["price.packs.d"]}

## Pages

- [English]({SITE}/)
- [Slovenčina]({SITE}/sk/)
- [Čeština]({SITE}/cs/)
- [Privacy]({SITE}/privacy), [Terms]({SITE}/terms), [Support]({SITE}/support)

## Social media

{social}

Publisher: missinghue s.r.o., Prague. Contact: hi@trubbo.app
"""


def strings_pass(page: str, lang: str, strings: dict, used: set) -> str:
    """Pass 2: visible strings. Keys ending in _html may carry inline markup; the rest is escaped."""

    def sub(match: re.Match) -> str:
        key = match.group(1)
        if key not in strings:
            raise KeyError(f"{lang}: missing string {key!r}")
        used.add(key)
        value = strings[key]
        return value if key.endswith("_html") else html.escape(value, quote=True)

    return KEY.sub(sub, page)


def render_legal(template: str, page: str, lang: str, strings: dict) -> str:
    """A legal page (privacy, terms, support) in one language, from src/legal/<page>.<lang>.html."""
    body = (SRC / "legal" / f"{page}.{lang}.html").read_text("utf-8").strip()
    if KEY.search(body):
        raise ValueError(f"legal/{page}.{lang}.html: placeholders are not allowed in legal text")
    title = re.search(r"<h1>(.*?)</h1>", body)
    if not title:
        raise ValueError(f"legal/{page}.{lang}.html: missing <h1>")
    generated = {
        "gen.lang": lang,
        "gen.page": page,
        "gen.title": TAG.sub("", title.group(1)),
        "gen.home": LANGS[lang],
        "gen.canonical": SITE + LANGS[lang] + page,
        "gen.alternates": alternates(page),
        "gen.switcher": switcher(lang, page),
        "gen.footer": footer(lang),
        "gen.body": body,
    }
    out = KEY.sub(lambda m: generated.get(m.group(1), m.group(0)), template)
    return strings_pass(out, lang, strings, set())


def render(template: str, lang: str, strings: dict) -> str:
    # Offer (never force) the browser's language: every page carries the three one-line prompts.
    suggest = {code: {"text": load(code)["suggest.text"], "go": load(code)["suggest.go"], "url": path}
               for code, path in LANGS.items()}

    # Pass 1: structure (partials and generated values), which may contain string keys.
    generated = {
        "gen.lang": lang,
        "gen.canonical": SITE + LANGS[lang],
        "gen.alternates": alternates(),
        "gen.switcher": switcher(lang),
        "gen.footer": footer(lang),
        "gen.jsonld": jsonld(lang, strings),
        "gen.suggest": json.dumps(suggest, ensure_ascii=False).replace("</", "<\\/"),
        "gen.screen": screen(0, live=True),
        **{f"gen.mini.{n}": screen(n, live=False) for n in range(STEPS)},
    }
    page = KEY.sub(lambda m: generated.get(m.group(1), m.group(0)), template)

    used = set()
    page = strings_pass(page, lang, strings, used)
    unused = set(strings) - used - {"suggest.text", "suggest.go"}
    if unused:
        raise KeyError(f"{lang}: unused strings {sorted(unused)}")
    return page


def main() -> int:
    template = (SRC / "template.html").read_text("utf-8")
    strings = {lang: load(lang) for lang in LANGS}
    base = set(strings["en"])
    errors = [e for lang in LANGS for e in lint(lang, strings[lang], base)]
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1

    if OUT.exists():
        shutil.rmtree(OUT)
    for lang, path in LANGS.items():
        target = OUT / path.strip("/") / "index.html"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(render(template, lang, strings[lang]), "utf-8")
        print(f"wrote {target.relative_to(ROOT)} ({target.stat().st_size:,} bytes)")
    # Legal pages as <page>.html: GitHub Pages serves them at the clean URL /<page> (and /sk/<page>, /cs/<page>).
    legal = (SRC / "legal.html").read_text("utf-8")
    for lang, path in LANGS.items():
        for page in LEGAL:
            target = OUT / path.strip("/") / f"{page}.html"
            target.write_text(render_legal(legal, page, lang, strings[lang]), "utf-8")
            print(f"wrote {target.relative_to(ROOT)} ({target.stat().st_size:,} bytes)")
    (OUT / "sitemap.xml").write_text(sitemap(), "utf-8")
    (OUT / "llms.txt").write_text(llms(strings), "utf-8")
    for name in STATIC:
        (OUT / name).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(SRC / name, OUT / name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
