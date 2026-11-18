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
    "uk": re.compile(r"\b(ви|вас|вам|вами|ваш(?!ингтон)\w*)\b", re.IGNORECASE),  # #231: «ти» except legal pages
}
# Plural imperative as the first word ("Skúste", "Zkuste", "Zadajte", "Спробуйте", "Натисніть").
FORMAL_IMPERATIVE = {
    "sk": re.compile(r"^(\w{3,}(?:ajte|ejte|ujte|ite|íte|ete|ste|te))\b"),
    "cs": re.compile(r"^(\w{3,}(?:ajte|ejte|ujte|ite|íte|ete|ste|te))\b"),
    # No «їть»: that is the third person («Стоїть на паузі»), not an imperative.
    "uk": re.compile(r"^(\w{2,}(?:йте|іть|ьте))\b"),
}
WRONG_SCRIPT = {"sk": re.compile(r"[řůě]"), "cs": re.compile(r"[äôľĺŕ]")}
# #231: Russian letters never occur in Ukrainian, and a Latin lookalike inside a
# Cyrillic word (Latin "i" for "і") breaks search and the voice. Always errors.
RUSSIAN = re.compile(r"[ыэъёЫЭЪЁ]")
# Russian words without ы э ъ ё (copy-style rule 24). Whole words, casefolded; local list on
# purpose: CI scripts must not import the app package (apps/quiz-pack-api/app/uk_policy.py).
RUSSIAN_WORDS = frozenset(
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
        "настройки",
        "настройка",
        "настройку",
        "начать",
        "начни",
        "игра",
        "игру",
        "играть",
        "вопрос",
        "вопросы",
        "ответ",
        "ответить",
        "киев",
        "продолжить",
        "сообщение",
        "пользователь",
        "язык",
        "спасибо",
        "пожалуйста",
    }
)
# Infinitive as a button (rule 22): the whole text is one or two words, e.g. «Підтвердити» (a consonant before «ти» is an imperative: «Пропусти»).
# Running text and questions («Видалити акаунт?») have more words or punctuation.
UK_INFINITIVE_BUTTON = re.compile(r"^[А-ЯІЇЄҐ][а-яіїєґ']{2,}[аеиіїоуєюя](?:ти|тися|тись)(?:\s[а-яіїєґ']+)?$")
UK_SESSION_EXPIRED = re.compile(r"сесі\w+\s+(закінчил|завершил|минул)", re.IGNORECASE)  # login expiry, rule 7 exception
MIXED_SCRIPT = re.compile(r"\w*(?:[а-яіїєґА-ЯІЇЄҐ][a-zA-Z]|[a-zA-Z][а-яіїєґА-ЯІЇЄҐ])\w*")
LANGS = ("en", "sk", "cs", "uk")
CONTRAST_TAIL = re.compile(
    r",\s(nie|ne|not)\s\w|\bnielen\b|\bnejen\b|\bnot (just|only)\b|,\sа\sне\s\w|\bне\s(лише|тільки|просто)\b",
    re.IGNORECASE,
)
STOCK_WORDS = re.compile(
    r"\b(seamless\w*|elevate\w*|unleash\w*|delve\w*|effortless\w*|immersive|vibrant|game-changer|"
    r"jedinečn\w+|bezproblémov\w+|revolučn\w+|ponor sa|ponoř se)\b",
    re.IGNORECASE,
)
TERMS = re.compile(r"\b(relácia|relácie|reláciu|relace|session|game|сесі\w+)\b", re.IGNORECASE)


def texts(value) -> list[str]:
    if value is None:
        return []
    return list(value.values()) if isinstance(value, dict) else [value]


def placeholders(value) -> list[str]:
    """Placeholder types, position-free: %1$lld and %lld are the same slot type."""
    found = PLACEHOLDER.findall(texts(value)[0]) if texts(value) else []
    return sorted(re.sub(r"\d+\$", "", p) for p in found)


def text_flags(lang: str, text: str, legal: bool = False) -> list[tuple[int, str, bool]]:
    """(rule, note, error) for one text; shared by app rows and other copy (store, web).

    Legal pages are formal by design (copy-style rule 1), so no address checks there.
    """
    found = []
    if DASH.search(text):
        found.append((5, f"dash: {text!r}", False))
    if lang in FORMAL and not legal:
        if FORMAL[lang].search(text):
            found.append((1, f"formal address: {text!r}", False))
        m = FORMAL_IMPERATIVE[lang].match(text)
        if m:
            found.append((1, f"possible plural imperative {m.group(1)!r}", False))
    if lang in WRONG_SCRIPT and WRONG_SCRIPT[lang].search(text):
        found.append((8, f"letters of the other language: {text!r}", False))
    if lang == "uk":  # copy-style rule 24
        if RUSSIAN.search(text):
            found.append((24, f"Russian letter {RUSSIAN.search(text).group(0)!r}: {text!r}", True))
        russian = RUSSIAN_WORDS & set(re.findall(r"[^\W\d_]+", text.casefold()))
        if russian:
            found.append((24, f"Russian word {min(russian)!r}: {text!r}", True))
        if UK_INFINITIVE_BUTTON.match(text) and not legal:
            found.append((22, f"possible infinitive button: {text!r}", False))
        if MIXED_SCRIPT.search(text):
            found.append((24, f"Latin and Cyrillic in one word {MIXED_SCRIPT.search(text).group(0)!r}", True))
    if CONTRAST_TAIL.search(text):
        found.append((12, f"contrast tail: {text!r}", False))
    if STOCK_WORDS.search(text):
        found.append((15, f"stock word {STOCK_WORDS.search(text).group(0)!r}", False))
    if "Hangs" in text:
        found.append((7, "code name in text", False))
    return found


def check(row: dict) -> list[dict]:
    flags = []

    def flag(lang, rule, note, error=False):
        flags.append({"id": row["id"], "lang": lang, "rule": rule, "note": note, "source": "check", "error": error})

    en_ph = placeholders(row["en"])
    for lang in LANGS:
        value = row.get(lang)
        if value is None:
            flag(lang, 8, "missing translation")
            continue
        for text in texts(value):
            for rule, note, error in text_flags(lang, text):
                flag(lang, rule, note, error)
            together = "#212" in row["comment"] or "Hra spolu" in row["comment"]  # multiplayer is a game
            expired = "vypršala" in text or "vypršela" in text or UK_SESSION_EXPIRED.search(text)
            if TERMS.search(text) and not together and not expired:
                flag(lang, 7, f"term: {TERMS.search(text).group(0)!r}")
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
    errors = sum(f["error"] for f in flags)
    print(f"{len(flags)} flags on {len({f['id'] for f in flags})} rows ({errors} errors); by rule {dict(sorted(by_rule.items()))} → {out}")
    if errors:
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
