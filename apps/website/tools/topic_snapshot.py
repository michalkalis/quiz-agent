"""Turn a production export + curated picks into src/topics/questions.<lang>.json (#223).

1. Export (read-only, on the quiz-agent-api machine; prints gzip+base64 JSON after "B64:"):
   fly ssh console -a quiz-agent-api -C "python -c \"import base64;exec(base64.b64decode('<base64 of tools/export_questions.py>'))\""
2. Pick ids per topic slug: {"<slug>": ["<question id>", ...]} (order = page order).
3. python3 tools/topic_snapshot.py <export.json> <picks.json> <lang>

Only text questions with an https source and a story are written. Dashes used as punctuation in the
story become commas (house rule for public text); questions or answers with such dashes are refused.
"""

import json
import re
import sys
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / "src" / "topics"
DASH = re.compile(r"\s+[–—]\s+|\s+-\s+")


def answer(row: dict) -> str:
    value = row["headline"] or row["answer"]
    try:
        value = json.loads(value)
    except (TypeError, ValueError):
        pass
    if isinstance(value, list):
        value = value[0]
    value = str(value).strip().strip('"')
    return value[:1].upper() + value[1:]  # shown on its own line, so it starts like a sentence


def story(text: str) -> str:
    text = DASH.sub(", ", text.strip())
    return re.sub(r"(?<=\d)[–—](?=\d)", "-", text)  # number ranges keep a plain hyphen


def main(export: str, picks: str, lang: str) -> int:
    rows = {}
    for r in json.loads(Path(export).read_text("utf-8")):
        if r["lang"] == lang:  # picks may use the full id or its first 8 characters
            rows[r["id"]] = rows[r["id"][:8]] = r
    chosen = json.loads(Path(picks).read_text("utf-8"))
    out = {}
    for slug, ids in chosen.items():
        items = []
        for qid in ids:
            r = rows[qid]
            if r["type"] != "text" or not (r["source_url"] or "").startswith("https://") or not r["explanation"]:
                raise SystemExit(f"{qid}: not publishable (type, source or story missing)")
            q, a = r["question"].strip(), answer(r)
            if re.search(r"[–—]", q + a):
                raise SystemExit(f"{qid}: dash in question or answer")
            items.append({"id": r["id"], "q": q, "a": a, "story": story(r["explanation"]), "source": r["source_url"]})
        out[slug] = items
    target = SRC / f"questions.{lang}.json"
    target.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", "utf-8")
    print(f"wrote {target} ({sum(map(len, out.values()))} questions)")
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
