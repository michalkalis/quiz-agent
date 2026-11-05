"""Cheap recall-first screen of all app texts with a non-Anthropic model (#226).

Sends each screen's strings together (file = screen context) with the copy
style rules to Gemini Flash and keeps every row it calls questionable. The
output only selects candidates for the pilot; it never edits a text.

Usage: uv run --no-sync python scripts/copy_review/screen.py ROWS.jsonl OUT.jsonl [model]
"""

import json
import sys
import time
import urllib.request
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from dotenv import dotenv_values

ROOT = Path(__file__).resolve().parents[2]
STYLE = (ROOT / "docs/design/copy-style.md").read_text(encoding="utf-8").split("## Review procedure")[0]
CHUNK = 40

PROMPT = """You are a native Slovak and Czech UX copy editor with excellent English.
Below are the user-facing strings of one screen of "Trubbo", an iOS trivia quiz
you play by voice (often hands-free, e.g. while driving). Each row has the
English source, the Slovak (sk) and Czech (cs) texts, a developer comment and
the Swift file it is used in. Texts are written by an AI, so look for what a
native speaker would notice.

House rules:
{style}

Flag every row/language that is QUESTIONABLE: a rule violation, grammar,
case or plural error, a calque or unnatural phrasing a native would not say,
a meaning that differs from the other languages, unclear or ambiguous wording,
inconsistent terms on the same screen. This is a recall-first screen: when in
doubt, flag it. Do not flag rows that are fine.

Return a JSON array, one object per problem:
{{"id": "<row id>", "lang": "en|sk|cs", "rule": "<rule number or 'style'>",
  "issue": "<one short sentence in English>", "suggestion": "<replacement text>"}}
Return [] when everything is fine.

Rows:
{rows}"""


def call(model: str, key: str, prompt: str) -> tuple[list, dict]:
    body = {
        "contents": [{"role": "user", "parts": [{"text": prompt}]}],
        "generationConfig": {"responseMimeType": "application/json", "temperature": 0.2},
    }
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(), headers={"x-goog-api-key": key, "Content-Type": "application/json"}
    )
    for attempt in range(4):
        try:
            data = json.load(urllib.request.urlopen(req, timeout=300))
            text = "".join(p.get("text", "") for p in data["candidates"][0]["content"]["parts"])
            return json.loads(text), data.get("usageMetadata", {})
        except Exception as exc:  # retry transient API/JSON errors, then fail loud
            if attempt == 3:
                raise
            print(f"retry after {exc!r}", file=sys.stderr)
            time.sleep(5 * (attempt + 1))
    raise AssertionError


def chunks(rows: list[dict]) -> list[list[dict]]:
    by_file: dict[str, list[dict]] = defaultdict(list)
    for row in rows:
        by_file[row["files"][0] if row["files"] else "unknown"].append(row)
    out = []
    for group in by_file.values():
        out += [group[i : i + CHUNK] for i in range(0, len(group), CHUNK)]
    return out


def main(rows_path: str, out: str, model: str = "gemini-3.8-flash") -> None:
    env = ROOT / ".env" if (ROOT / ".env").exists() else Path.home() / "code/quiz-agent/.env"  # worktrees have no .env
    key = dotenv_values(env).get("GOOGLE_API_KEY")
    rows = [json.loads(line) for line in Path(rows_path).read_text(encoding="utf-8").splitlines()]
    rows = [r for r in rows if not r["stale"]]
    ids = {r["id"] for r in rows}
    fields = ("id", "en", "sk", "cs", "comment", "files")

    def run(group):
        payload = json.dumps([{k: r[k] for k in fields} for r in group], ensure_ascii=False, indent=0)
        return call(model, key, PROMPT.format(style=STYLE, rows=payload))

    flags, tokens_in, tokens_out = [], 0, 0
    with ThreadPoolExecutor(4) as pool:
        for found, usage in pool.map(run, chunks(rows)):
            tokens_in += usage.get("promptTokenCount", 0)
            tokens_out += usage.get("candidatesTokenCount", 0) + usage.get("thoughtsTokenCount", 0)
            flags += [{**f, "source": model} for f in found if f.get("id") in ids]
    with open(out, "w", encoding="utf-8") as fh:
        fh.writelines(json.dumps(f, ensure_ascii=False) + "\n" for f in flags)
    print(f"{len(flags)} flags on {len({f['id'] for f in flags})} rows; tokens in {tokens_in}, out {tokens_out} → {out}")


if __name__ == "__main__":
    main(*sys.argv[1:])
