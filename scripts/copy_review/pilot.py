"""Pilot review of questionable texts by two independent non-Anthropic models (#226).

Targets = rows flagged by checks.py or screen.py, plus a small control sample of
unflagged rows (measures over-flagging). Each reviewer sees the whole screen as
context but reviews only the target rows, and never sees the earlier flags, so
the two verdicts stay independent.

Usage: uv run --no-project --with python-dotenv python scripts/copy_review/pilot.py RUN_DIR
"""

import json
import random
import sys
import time
import urllib.request
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from dotenv import dotenv_values

ROOT = Path(__file__).resolve().parents[2]
ENV = dotenv_values(ROOT / ".env" if (ROOT / ".env").exists() else Path.home() / "code/quiz-agent/.env")
STYLE = (ROOT / "docs/design/copy-style.md").read_text(encoding="utf-8").split("## Review procedure")[0]
REVIEWERS = {"gemini": "gemini-3.1-pro-preview", "gpt": "gpt-5.5"}
CONTROL = 25
FIELDS = ("id", "en", "sk", "cs", "comment", "files")

PROMPT = """You are a senior native Slovak and native Czech localization reviewer
(LQA, MQM method) with excellent English. You review the user-facing texts of
"Trubbo", an iOS trivia quiz played by voice, often hands-free. The texts were
written by another AI.

House rules (a violation is always a finding):
{style}

Product context: "Hra spolu" (sk, cs) / "Play together" (en) is the
multiplayer feature (same room, several phones); there "hra" / "game" is the
correct word. A solo run is a "kvíz" / "quiz". Running text naming a button
must match that button's label as shown in the context.

SCREEN CONTEXT: strings of the screen, so you can judge consistency:
{context}

REVIEW ONLY these row ids: {targets}

For every target row and each language (en, sk, cs), report a finding only
when a native speaker or the house rules would demand a change: grammar,
case, plural, a calque or unnatural phrasing, meaning that differs between
languages, wrong term, rule violation, unclear text. Taste alone is not a
finding. Give the exact full replacement text.

Return JSON: {{"findings": [{{"id": "...", "lang": "en|sk|cs",
 "category": "accuracy|grammar|fluency|terminology|style|rule",
 "rule": "<house rule number or null>", "severity": "minor|major|critical",
 "issue": "<one sentence in English>", "fix": "<full replacement text>"}}]}}
Return {{"findings": []}} if every target row is fine."""


def post(url: str, body: dict, headers: dict) -> dict:
    req = urllib.request.Request(url, json.dumps(body).encode(), {**headers, "Content-Type": "application/json"})
    for attempt in range(4):
        try:
            return json.load(urllib.request.urlopen(req, timeout=600))
        except Exception as exc:  # transient API errors: retry, then fail loud
            if attempt == 3:
                raise
            print(f"retry after {exc!r}", file=sys.stderr)
            time.sleep(10 * (attempt + 1))
    raise AssertionError


def ask_gemini(prompt: str) -> tuple[str, int, int]:
    data = post(
        f"https://generativelanguage.googleapis.com/v1beta/models/{REVIEWERS['gemini']}:generateContent",
        {"contents": [{"role": "user", "parts": [{"text": prompt}]}],
         "generationConfig": {"responseMimeType": "application/json", "thinkingConfig": {"thinkingLevel": "low"}}},
        {"x-goog-api-key": ENV["GOOGLE_API_KEY"]},
    )
    u = data.get("usageMetadata", {})
    text = "".join(p.get("text", "") for p in data["candidates"][0]["content"]["parts"])
    return text, u.get("promptTokenCount", 0), u.get("candidatesTokenCount", 0) + u.get("thoughtsTokenCount", 0)


def ask_gpt(prompt: str) -> tuple[str, int, int]:
    data = post(
        "https://api.openai.com/v1/responses",
        {"model": REVIEWERS["gpt"], "input": prompt, "reasoning": {"effort": "low"},
         "text": {"format": {"type": "json_object"}}},
        {"Authorization": f"Bearer {ENV['OPENAI_API_KEY']}"},
    )
    u = data.get("usage", {})
    return data["output_text"] if "output_text" in data else next(
        c["text"] for o in data["output"] if o["type"] == "message" for c in o["content"] if c["type"] == "output_text"
    ), u.get("input_tokens", 0), u.get("output_tokens", 0)


def load(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()] if path.exists() else []


def main(run_dir: str) -> None:
    run = Path(run_dir)
    rows = [r for r in load(run / "rows.jsonl") if not r["stale"]]
    flagged = {f["id"] for f in load(run / "check-flags.jsonl") + load(run / "screen-flags.jsonl")}
    unflagged = sorted(r["id"] for r in rows if r["id"] not in flagged)
    control = set(random.Random(226).sample(unflagged, min(CONTROL, len(unflagged))))
    targets = flagged | control
    (run / "pilot-targets.json").write_text(json.dumps({"flagged": sorted(flagged), "control": sorted(control)}, indent=1))

    screens: dict[str, list[dict]] = defaultdict(list)
    for r in rows:
        screens[r["files"][0] if r["files"] else "unknown"].append(r)
    jobs = []
    for group in screens.values():
        ids = [r["id"] for r in group if r["id"] in targets]
        for i in range(0, len(ids), 30):
            chunk = set(ids[i : i + 30])
            near = {j for j, r in enumerate(group) if r["id"] in chunk for j in range(j - 3, j + 4)}
            ctx = group if len(group) <= 60 else [r for j, r in enumerate(group) if j in near]
            context = json.dumps([{k: r[k] for k in FIELDS} for r in ctx], ensure_ascii=False, indent=0)
            jobs.append(PROMPT.format(style=STYLE, context=context, targets=json.dumps(ids[i : i + 30], ensure_ascii=False)))
    est = sum(len(j) for j in jobs) // 3  # ~3 chars per token for sk/cs JSON
    print(f"{len(flagged)} flagged + {len(control)} control rows in {len(jobs)} calls, ~{est} input tokens per reviewer")
    if "--dry-run" in sys.argv:
        return

    for name, ask in (("gemini", ask_gemini), ("gpt", ask_gpt)):
        findings, tin, tout = [], 0, 0
        with ThreadPoolExecutor(4) as pool:
            for text, i, o in pool.map(ask, jobs):
                findings += [f for f in json.loads(text)["findings"] if f.get("id") in targets]
                tin, tout = tin + i, tout + o
        with open(run / f"pilot-{name}.jsonl", "w", encoding="utf-8") as fh:
            fh.writelines(json.dumps(f, ensure_ascii=False) + "\n" for f in findings)
        print(f"{name} ({REVIEWERS[name]}): {len(findings)} findings, tokens in {tin} out {tout}")


if __name__ == "__main__":
    main(sys.argv[1])  # add --dry-run to print the size only
