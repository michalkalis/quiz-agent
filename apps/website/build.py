#!/usr/bin/env python3
"""Generate the static trubbo.app site from src/ into public/ (what GitHub Pages serves).

Inputs: src/template.html, src/footer.html, src/mascot.svg (inlined so the mascot can blink),
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
# Trubbo on the App Store: the local storefront for Slovak and Czech, Apple's own redirect for everyone else.
APP_STORE_ID = "6762482437"
STORE = {
    "en": f"https://apps.apple.com/app/id{APP_STORE_ID}",
    "sk": f"https://apps.apple.com/sk/app/trubbo/id{APP_STORE_ID}",
    "cs": f"https://apps.apple.com/cz/app/trubbo/id{APP_STORE_ID}",
}
BETA = "https://testflight.apple.com/join/qvbqMh1k"
FONT_FILES = ["funnel-display-latin.woff2", "funnel-display-latin-ext.woff2", "funnel-sans-latin.woff2", "funnel-sans-latin-ext.woff2"]
STATIC = [*FONT_FILES, "funnel-OFL.txt", "app-store-badge.svg", "favicon.svg", "favicon.png", "apple-touch-icon.png", "mascot.svg", "mail-logo.png", "og.png", "robots.txt", "404.html", "CNAME", "join.html", "googlee2ff1698bc168aef.html", ".well-known/apple-app-site-association"]

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


# Funnel Display (headings) and Funnel Sans (text), SIL OFL, self-hosted; Latin + Latin Extended split like Google Fonts.
LATIN_EXT = "U+0100-02BA,U+02BD-02C5,U+02C7-02CC,U+02CE-02D7,U+02DD-02FF,U+0304,U+0308,U+0329,U+1D00-1DBF,U+1E00-1E9F,U+1EF2-1EFF,U+2020,U+20A0-20AB,U+20AD-20C4,U+2113,U+2C60-2C7F,U+A720-A7FF"
LATIN = "U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD"
FONTS = "\n".join(
    f'@font-face{{font-family:"{family}";font-style:normal;font-weight:300 800;font-display:swap;'
    f'src:url(/{slug}-{subset}.woff2) format("woff2");unicode-range:{rng}}}'
    for family, slug in (("Funnel Display", "funnel-display"), ("Funnel Sans", "funnel-sans"))
    for subset, rng in (("latin-ext", LATIN_EXT), ("latin", LATIN))
)
EYES = re.compile(r'<circle cx="81" [^>]*/><circle cx="84\.3" [^>]*/><circle cx="123" [^>]*/><circle cx="126\.3" [^>]*/>')


def mascot() -> str:
    """The mascot inline, eyes wrapped in groups the page animates (blink, glance aside)."""
    svg = (SRC / "mascot.svg").read_text("utf-8").strip()
    if len(EYES.findall(svg)) != 1:
        raise ValueError("mascot.svg: eye circles not found; update EYES in build.py to the new drawing")
    svg = EYES.sub(lambda m: f'<g class="mk-look"><g class="mk-blink">{m.group(0)}</g></g>', svg)
    return svg.replace("<svg ", '<svg focusable="false" ', 1)


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
           "installUrl": STORE[lang], "downloadUrl": STORE[lang], "downloadUrl": STORE[lang],
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

App Store: {STORE["en"]}

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
        "gen.fonts": FONTS,
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
        "gen.fonts": FONTS,
        "gen.mascot": mascot(),
        "gen.store": STORE[lang],
        "gen.store.id": APP_STORE_ID,
        "gen.beta": BETA,
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
    # "Hear the question" recordings, one per language (src/audio/question-<lang>.mp3); the page falls back to
    # the browser's voice while one is missing.
    if (SRC / "audio").is_dir():
        shutil.copytree(SRC / "audio", OUT / "audio")
    return 0


if __name__ == "__main__":
    sys.exit(main())
