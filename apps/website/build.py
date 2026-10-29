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
    """Footer partial with links to the legal pages in the same language; its text keys stay for pass 2."""
    return (SRC / "footer.html").read_text("utf-8").strip().replace("{{gen.home}}", LANGS[lang])


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
    for name in STATIC:
        (OUT / name).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(SRC / name, OUT / name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
