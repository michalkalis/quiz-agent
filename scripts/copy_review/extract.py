"""Extract every app UI string (en/sk/cs) with its context for copy review (#226).

Context per row: developer comment, the Swift files that use the key, and the
row's neighbours in the same file (so a reviewer sees the screen, not one line).

Usage: uv run --no-sync python scripts/copy_review/extract.py OUT.jsonl
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps/ios-app/Hangs/Hangs"
CATALOGS = ["Localizable.xcstrings", "InfoPlist.xcstrings"]
LANGS = ["en", "sk", "cs"]


def unit_value(loc: dict) -> str | dict | None:
    """A plain string, or {plural form: string} for plural variants."""
    if "stringUnit" in loc:
        return loc["stringUnit"]["value"]
    plural = loc.get("variations", {}).get("plural")
    if plural:
        return {form: v["stringUnit"]["value"] for form, v in plural.items()}
    return None


def swift_sources() -> dict[str, str]:
    return {
        str(p.relative_to(APP)): p.read_text(encoding="utf-8")
        for p in APP.rglob("*.swift")
    }


def usages(key: str, sources: dict[str, str]) -> list[str]:
    # Interpolated keys (`%@`, `%lld`) appear in Swift as "\(...)": match the
    # literal text before the first placeholder instead.
    probe = re.split(r"%(?:\d+\$)?(?:@|lld|ld|d|f|\.\d+f)", key)[0].strip()
    needle = f'"{key}"' if probe == key.strip() else probe
    if len(needle) < 4:
        return []
    return [path for path, text in sources.items() if needle in text][:3]


def main(out: str) -> None:
    sources = swift_sources()
    rows = []
    for catalog in CATALOGS:
        data = json.loads((APP / catalog).read_text(encoding="utf-8"))
        for key, entry in data["strings"].items():
            if entry.get("shouldTranslate") is False:
                continue
            locs = entry.get("localizations", {})
            values = {lang: unit_value(locs[lang]) if lang in locs else None for lang in LANGS}
            if values["en"] is None:
                values["en"] = key  # source language: the key is the English text
            rows.append(
                {
                    "id": f"{catalog.split('.')[0]}:{key}",
                    "catalog": catalog,
                    "key": key,
                    **values,
                    "comment": entry.get("comment", ""),
                    "stale": entry.get("extractionState") == "stale",
                    "files": usages(key, sources) if catalog.startswith("Localizable") else ["Info.plist"],
                }
            )
    with open(out, "w", encoding="utf-8") as fh:
        fh.writelines(json.dumps(row, ensure_ascii=False) + "\n" for row in rows)
    used = sum(1 for r in rows if r["files"])
    print(f"{len(rows)} rows, {used} with a source file, {sum(r['stale'] for r in rows)} stale → {out}")


if __name__ == "__main__":
    main(sys.argv[1])
