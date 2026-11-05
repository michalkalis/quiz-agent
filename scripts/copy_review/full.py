"""Full copy review of every player-facing text by Gemini 3.1 Pro (#226 step 226.7).

Sources: app string catalog rows the pilot did not review, spoken prompts and
voice-command hints (Swift), App Store listing, website strings, topic pages
and legal pages. Every call carries its context; findings only, never edits.
Stops before the founder's budget would be crossed (default $3.9).

Usage: uv run --no-project --with python-dotenv python scripts/copy_review/full.py RUN_DIR PILOT_DIR [--budget=3.9] [--dry-run]
"""

import json
import sys
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from pilot import FIELDS, PRICES, REVIEWERS, STYLE, ask_gemini, load

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps/ios-app/Hangs/Hangs"
WEB = ROOT / "apps/website/src"
STORE = ROOT / "apps/ios-app/Hangs/fastlane/metadata"
LANGS = ("en", "sk", "cs")
PILOT_CALLS = 64  # pilot run 2026-11-04 stopped at its $0.95 cap after 64 of 71 calls

HEAD = """You are a senior native Slovak and native Czech localization reviewer
(LQA, MQM method) with excellent English. You review player-facing texts of
"Trubbo", an iOS trivia quiz played by voice, often hands-free. The texts
were written by another AI.

House rules (a violation is always a finding):
{style}
Product context: "Hra spolu" (sk, cs) / "Play together" (en) is the multiplayer
feature, where "hra" / "game" is correct; a solo run is a "kvíz" / "quiz".
Two different "next" actions: „Ďalšia“ / „Další“ / "Next" moves on to the next
question (button and voice command); „Ďalej“ / „Dál“ continues after a result.

SOURCE: {source}
"""

TAIL = """
Report a finding only when a native speaker or the house rules would demand a
change: grammar, case, plural, a calque or unnatural phrasing, meaning that
differs between languages, wrong term, rule violation, unclear text. Taste
alone is not a finding. Quote the exact current text and give the exact full
replacement.

Return JSON: {{"findings": [{{"id": "<item id>", "lang": "en|sk|cs",
 "category": "accuracy|grammar|fluency|terminology|style|rule",
 "rule": "<house rule number or null>", "severity": "minor|major|critical",
 "issue": "<one sentence in English>", "quote": "<exact current text>",
 "fix": "<full replacement text>"}}]}}
Return {{"findings": []}} if everything is fine."""


def rows_job(source: str, context: list[dict], targets: list[str]) -> dict:
    body = "CONTEXT (all items of this screen/page):\n" + json.dumps(context, ensure_ascii=False, indent=0)
    body += f"\n\nREVIEW ONLY these item ids: {json.dumps(targets, ensure_ascii=False)}"
    return {"source": source, "prompt": HEAD.format(style=STYLE, source=source) + body + TAIL}


def doc_job(source: str, text: str, ids: str) -> dict:
    body = f"DOCUMENT (review only the player-visible text, not code or markup; use id {ids}):\n{text}"
    return {"source": source, "prompt": HEAD.format(style=STYLE, source=source) + body + TAIL}


def app_jobs(run: Path, pilot: Path) -> list[dict]:
    rows = [r for r in load(run / "rows.jsonl") if not r["stale"]]
    targets = json.loads((pilot / "pilot-targets.json").read_text())
    reviewed = set(targets["flagged"]) | set(targets["control"])
    # The pilot stopped at its budget after PILOT_CALLS calls: rebuild its call
    # order (same grouping and chunking as pilot.py) to find the unreviewed rows.
    pilot_rows = [r for r in load(pilot / "rows.jsonl") if not r["stale"]]
    by_screen: dict[str, list[str]] = defaultdict(list)
    for r in pilot_rows:
        if r["id"] in reviewed:
            by_screen[r["files"][0] if r["files"] else "unknown"].append(r["id"])
    pilot_calls = [ids[i : i + 30] for ids in by_screen.values() for i in range(0, len(ids), 30)]
    reviewed -= {i for call in pilot_calls[PILOT_CALLS:] for i in call}
    todo = {r["id"] for r in rows if r["id"] not in reviewed}
    screens: dict[str, list[dict]] = defaultdict(list)
    for r in rows:
        screens[r["files"][0] if r["files"] else "unknown"].append(r)
    jobs = []
    for screen, group in screens.items():
        ids = [r["id"] for r in group if r["id"] in todo]
        for i in range(0, len(ids), 30):
            chunk = set(ids[i : i + 30])
            near = {j for j, r in enumerate(group) if r["id"] in chunk for j in range(j - 3, j + 4)}
            ctx = group if len(group) <= 60 else [r for j, r in enumerate(group) if j in near]
            jobs.append(rows_job(f"iOS app screen {screen}", [{k: r[k] for k in FIELDS} for r in ctx], ids[i : i + 30]))
    return jobs


def keyed_job(source: str, files: dict[str, Path], note: str = "") -> dict:
    data = {lang: json.loads(p.read_text(encoding="utf-8")) for lang, p in files.items()}
    keys = sorted(set().union(*data.values()))
    items = [{"id": k, **{lang: data[lang].get(k) for lang in data}} for k in keys]
    return rows_job(source + note, items, [i["id"] for i in items])


def store_job() -> dict:
    limits = {"name": 30, "subtitle": 30, "keywords": 100, "promotional_text": 170}
    items = []
    for field in ("name", "subtitle", "promotional_text", "description", "keywords", "release_notes"):
        item = {"id": f"store:{field}", "comment": f"App Store {field}" + (f", max {limits[field]} characters" if field in limits else "")}
        for lang, folder in (("en", "en-US"), ("en-GB", "en-GB"), ("sk", "sk"), ("cs", "cs")):
            item[lang] = (STORE / folder / f"{field}.txt").read_text(encoding="utf-8").strip()
        items.append(item)
    return rows_job("App Store listing (en-US = en, en-GB, sk, cs); keywords are comma-separated search terms", items, [i["id"] for i in items])


def all_jobs(run: Path, pilot: Path) -> list[dict]:
    jobs = app_jobs(run, pilot)
    for name in ("SpokenPrompt", "VoiceCommandLexicon+Display", "VoiceCommandLexicon+Buttons", "VoiceCommandLexicon+Sheet"):
        src = (APP / f"Utilities/{name}.swift").read_text(encoding="utf-8")
        jobs.append(doc_job(f"Swift source {name}.swift: texts the app SPEAKS aloud (TTS) or shows as voice-command hints, per language", src, f'"{name}:<line number>"'))
    jobs.append(store_job())
    jobs.append(keyed_job("Website trubbo.app landing page strings (keys ending _html may contain markup)", {lang: WEB / f"strings/{lang}.json" for lang in LANGS}))
    jobs.append(keyed_job("Website question topic pages: page chrome strings; keys differ by language where slugs are localized", {lang: WEB / f"topics/{lang}.json" for lang in LANGS}))
    for page in ("support", "terms", "privacy"):
        text = "\n\n".join(f"=== {lang} ===\n" + (WEB / f"legal/{page}.{lang}.html").read_text(encoding="utf-8") for lang in LANGS)
        jobs.append(doc_job(f"Website legal page '{page}' in en, sk, cs (language quality only; do not change legal meaning)", text, f'"legal:{page}"'))
    return jobs


def main(run_dir: str, pilot_dir: str) -> None:
    run, pilot = Path(run_dir), Path(pilot_dir)
    budget = float(next((a.split("=")[1] for a in sys.argv if a.startswith("--budget=")), "3.9"))
    jobs = all_jobs(run, pilot)
    print(f"{len(jobs)} calls, ~{sum(len(j['prompt']) for j in jobs) // 3} input tokens")
    if "--dry-run" in sys.argv:
        return
    price_in, price_out = PRICES[REVIEWERS["gemini"]]
    findings, tin, tout, done = [], 0, 0, 0
    with ThreadPoolExecutor(4) as pool:
        for start in range(0, len(jobs), 4):
            cost = (tin * price_in + tout * price_out) / 1e6
            if cost + 4 * (cost / done if done else 0) > budget:  # founder cap
                print(f"budget ${budget} reached after {done}/{len(jobs)} calls", file=sys.stderr)
                break
            batch = jobs[start : start + 4]
            for job, (text, i, o) in zip(batch, pool.map(lambda j: ask_gemini(j["prompt"]), batch)):
                findings += [{**f, "source": job["source"]} for f in json.loads(text)["findings"]]
                tin, tout, done = tin + i, tout + o, done + 1
    with open(run / "full-gemini.jsonl", "w", encoding="utf-8") as fh:
        fh.writelines(json.dumps(f, ensure_ascii=False) + "\n" for f in findings)
    cost = (tin * price_in + tout * price_out) / 1e6
    print(f"{done}/{len(jobs)} calls, {len(findings)} findings, ~${cost:.2f}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
