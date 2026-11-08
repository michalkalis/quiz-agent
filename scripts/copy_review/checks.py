"""Deterministic copy checks from docs/design/copy-style.md (#226).

Cheap first pass: flags candidates only, a reviewer model decides. Each flag
names the copy-style rule number it comes from.

Usage: uv run --no-sync python scripts/copy_review/checks.py ROWS.jsonl OUT.jsonl
"""

import json
import re
import sys
from pathlib import Path

PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:@|lld|ld|d|f|\.\d+f)")
DASH = re.compile(r"(?<![0-9A-Z])[—–]|[—–](?![0-9A-Z])|\s-\s")  # ranges like 1–4, A–D are fine
FORMAL = {
    "sk": re.compile(r"\b(Vy|Vás|Vám|Vami|Váš|Vaš\w+|vaš\w+|váš)\b"),
    "cs": re.compile(r"\b(Vy|Vás|Vám|Vámi|Váš|Vaš\w+|vaš\w+|váš)\b"),
}
# Plural imperative as the first word ("Skúste", "Zkuste", "Zadajte").
FORMAL_IMPERATIVE = re.compile(r"^(\w{3,}(?:ajte|ejte|ujte|ite|íte|ete|ste|te))\b")
WRONG_SCRIPT = {"sk": re.compile(r"[řůě]"), "cs": re.compile(r"[äôľĺŕ]")}
CONTRAST_TAIL = re.compile(r",\s(nie|ne|not)\s\w|\bnielen\b|\bnejen\b|\bnot (just|only)\b", re.IGNORECASE)
STOCK_WORDS = re.compile(
    r"\b(seamless\w*|elevate\w*|unleash\w*|delve\w*|effortless\w*|immersive|vibrant|game-changer|"
    r"jedinečn\w+|bezproblémov\w+|revolučn\w+|ponor sa|ponoř se)\b",
    re.IGNORECASE,
)
TERMS = re.compile(r"\b(relácia|relácie|reláciu|relace|session|game)\b", re.IGNORECASE)


def texts(value) -> list[str]:
    if value is None:
        return []
    return list(value.values()) if isinstance(value, dict) else [value]


def placeholders(value) -> list[str]:
    """Placeholder types, position-free: %1$lld and %lld are the same slot type."""
    found = PLACEHOLDER.findall(texts(value)[0]) if texts(value) else []
    return sorted(re.sub(r"\d+\$", "", p) for p in found)


def check(row: dict) -> list[dict]:
    flags = []

    def flag(lang, rule, note):
        flags.append({"id": row["id"], "lang": lang, "rule": rule, "note": note, "source": "check"})

    en_ph = placeholders(row["en"])
    for lang in ("en", "sk", "cs"):
        value = row[lang]
        if value is None:
            flag(lang, 8, "missing translation")
            continue
        for text in texts(value):
            if DASH.search(text):
                flag(lang, 5, f"dash: {text!r}")
            if lang in FORMAL and FORMAL[lang].search(text):
                flag(lang, 1, f"formal address: {text!r}")
            if lang in FORMAL:
                m = FORMAL_IMPERATIVE.match(text)
                if m:
                    flag(lang, 1, f"possible plural imperative {m.group(1)!r}")
            if lang in WRONG_SCRIPT and WRONG_SCRIPT[lang].search(text):
                flag(lang, 8, f"letters of the other language: {text!r}")
            together = "#212" in row["comment"] or "Hra spolu" in row["comment"]  # multiplayer is a game
            if TERMS.search(text) and not together and "vypršala" not in text and "vypršela" not in text:
                flag(lang, 7, f"term: {TERMS.search(text).group(0)!r}")
            if CONTRAST_TAIL.search(text):
                flag(lang, 12, f"contrast tail: {text!r}")
            if STOCK_WORDS.search(text):
                flag(lang, 15, f"stock word {STOCK_WORDS.search(text).group(0)!r}")
            if "Hangs" in text:
                flag(lang, 7, "code name in text")
        if lang != "en":
            if placeholders(value) != en_ph:
                flag(lang, 11, f"placeholders {placeholders(value)} vs en {en_ph}")
            if isinstance(value, str) and re.search(r"%(lld|ld|d)\b", value):
                flag(lang, 6, "count without plural variants")
            en_text = texts(row["en"])[0]
            if isinstance(value, str) and value == en_text and re.search(r"[a-z]{4}", value) and "Trubbo" not in value:
                flag(lang, 8, "identical to English (untranslated?)")
            if isinstance(value, str) and len(en_text) <= 20 and len(value) > max(16, 1.6 * len(en_text)):
                flag(lang, 9, f"much longer than en ({len(value)} vs {len(en_text)} chars)")
    return flags


def main(rows_path: str, out: str) -> None:
    rows = [json.loads(line) for line in Path(rows_path).read_text(encoding="utf-8").splitlines()]
    flags = [f for row in rows if not row["stale"] for f in check(row)]
    with open(out, "w", encoding="utf-8") as fh:
        fh.writelines(json.dumps(f, ensure_ascii=False) + "\n" for f in flags)
    by_rule: dict[int, int] = {}
    for f in flags:
        by_rule[f["rule"]] = by_rule.get(f["rule"], 0) + 1
    print(f"{len(flags)} flags on {len({f['id'] for f in flags})} rows; by rule {dict(sorted(by_rule.items()))} → {out}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
