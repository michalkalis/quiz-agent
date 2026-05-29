"""Audit question-answer quality across data/generated and the prod export.

Read-only: emits a JSON + HTML report to docs/artifacts/. Does not mutate
source files. Category overlap is allowed — one question can land in multiple
buckets (e.g. an em-dash explanation that is also verbose).

Issue #42 task 42.1. See docs/issues/issue-42-question-quality-and-mcq.md.
"""

from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from datetime import date
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
GENERATED_DIR = REPO_ROOT / "data" / "generated"
PROD_EXPORT = REPO_ROOT / "apps" / "quiz-agent" / "questions_export.json"
ARTIFACTS_DIR = REPO_ROOT / "docs" / "artifacts"

# Procedural: imperative-verb starts + multi-step language. Long enough to be
# clearly an algorithm rather than a value answer.
PROCEDURAL_STARTERS = {
    "fill", "pour", "empty", "light", "tie", "cut", "place", "take",
    "start", "open", "begin", "step", "first,", "first ", "press",
    "rotate", "swap", "move",
}
PROCEDURAL_MIN_WORDS = 20

# Em-dash / explanation delimiters in the answer field. These signal
# "value — explanation" smushed into correct_answer.
EM_DASH_RE = re.compile(r"[—–]")
EXPLAIN_TOKEN_RE = re.compile(r"\b(because|namely)\b", re.IGNORECASE)

# Verbose: any answer beyond the 10-word target.
VERBOSE_THRESHOLD = 10

# true_false-as-text: answer starts with True/False (any language fallback to EN).
TRUE_FALSE_RE = re.compile(r"^\s*(true|false|pravda|nepravda)\b", re.IGNORECASE)

# Options-in-question-text: A, B, C, D inline in the question body. Patterns:
# - "Which is older: A) basketball or B) marathon?"
# - "A, the marathon, or B, basketball"
# - "(A) Jupiter (B) Mars"
OPTIONS_IN_TEXT_RE = re.compile(
    r"\b[Aa]\)\s|\([Aa]\)|"  # A) or (A)
    r"\b[Aa],\s+[a-z].*\bor\s+[Bb][,)]|"  # "A, the ... or B,"
    r":\s*[Aa]\b.*\bor\s+[Bb]\b",  # "Which is X: A ... or B"
)


def _word_count(text: str) -> int:
    return len(text.split())


def _classify(question: dict[str, Any]) -> set[str]:
    cats: set[str] = set()
    ans = (question.get("correct_answer") or "").strip()
    qtext = (question.get("question") or "").strip()
    qtype = (question.get("type") or "").strip()
    wc = _word_count(ans)

    if EM_DASH_RE.search(ans) or EXPLAIN_TOKEN_RE.search(ans):
        cats.add("em_dash_explanation")

    if wc > VERBOSE_THRESHOLD:
        cats.add("verbose")

    if wc >= PROCEDURAL_MIN_WORDS:
        first_token = ans.split(maxsplit=1)[0].lower() if ans else ""
        starter_hit = first_token in PROCEDURAL_STARTERS or any(
            ans.lower().startswith(s) for s in PROCEDURAL_STARTERS
        )
        multi_sentence = ans.count(".") >= 2
        if starter_hit and multi_sentence:
            cats.add("procedural")

    if qtype == "text" and TRUE_FALSE_RE.match(ans):
        cats.add("true_false_as_text")

    if OPTIONS_IN_TEXT_RE.search(qtext):
        cats.add("options_in_question_text")

    return cats


def _iter_questions(path: Path):
    data = json.loads(path.read_text())
    qs = data["questions"] if isinstance(data, dict) and "questions" in data else data
    for idx, q in enumerate(qs):
        yield idx, q


def _collect_files() -> list[Path]:
    files = sorted(GENERATED_DIR.glob("*.json"))
    if PROD_EXPORT.exists():
        files.append(PROD_EXPORT)
    return files


def audit() -> dict[str, Any]:
    files = _collect_files()
    by_category: dict[str, list[dict[str, Any]]] = defaultdict(list)
    total = 0

    for fp in files:
        rel = str(fp.relative_to(REPO_ROOT))
        for idx, q in _iter_questions(fp):
            total += 1
            cats = _classify(q)
            if not cats:
                continue
            entry = {
                "file": rel,
                "index": idx,
                "id": q.get("id"),
                "question": (q.get("question") or "")[:160],
                "correct_answer": q.get("correct_answer"),
                "type": q.get("type"),
            }
            for c in cats:
                by_category[c].append(entry)

    counts = {c: len(v) for c, v in by_category.items()}
    return {
        "generated_on": date.today().isoformat(),
        "files_scanned": [str(p.relative_to(REPO_ROOT)) for p in files],
        "questions_scanned": total,
        "counts": counts,
        "categories": dict(by_category),
    }


def _render_html(report: dict[str, Any]) -> str:
    counts_rows = "".join(
        f"<tr><td>{c}</td><td>{n}</td></tr>"
        for c, n in sorted(report["counts"].items(), key=lambda kv: -kv[1])
    )
    sections = []
    for cat, entries in sorted(report["categories"].items()):
        rows = "".join(
            f"<tr><td>{e['file']}</td><td>{e['index']}</td>"
            f"<td>{(e['question'] or '')[:120]}</td>"
            f"<td>{(e['correct_answer'] or '')[:200]}</td></tr>"
            for e in entries[:50]
        )
        sections.append(
            f"<details><summary><b>{cat}</b> ({len(entries)})</summary>"
            f"<table><thead><tr><th>file</th><th>idx</th><th>question</th>"
            f"<th>answer</th></tr></thead><tbody>{rows}</tbody></table>"
            f"</details>"
        )
    body = "".join(sections)
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Answer Quality Audit</title>
<style>
body {{ font-family: -apple-system, sans-serif; max-width: 1200px; margin: 2em auto; padding: 0 1em; }}
table {{ border-collapse: collapse; width: 100%; font-size: 13px; }}
th, td {{ border: 1px solid #ddd; padding: 4px 8px; text-align: left; vertical-align: top; }}
th {{ background: #f4f4f4; }}
details {{ margin: 1em 0; }}
summary {{ cursor: pointer; padding: .5em; background: #fafafa; }}
.meta {{ color: #666; font-size: 13px; }}
</style></head>
<body>
<h1>Answer Quality Audit — {report["generated_on"]}</h1>
<p class="meta">Scanned {report["questions_scanned"]} questions across
{len(report["files_scanned"])} files. Issue #42 task 42.1.</p>
<h2>Counts</h2>
<table><thead><tr><th>category</th><th>n</th></tr></thead>
<tbody>{counts_rows}</tbody></table>
<h2>Findings</h2>
{body}
</body></html>
"""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=ARTIFACTS_DIR,
        help="Where to write the JSON + HTML report.",
    )
    args = parser.parse_args()

    report = audit()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    stamp = report["generated_on"]
    json_path = args.out_dir / f"answer-quality-audit-{stamp}.json"
    html_path = args.out_dir / f"answer-quality-audit-{stamp}.html"
    json_path.write_text(json.dumps(report, indent=2, ensure_ascii=False))
    html_path.write_text(_render_html(report))

    print(f"scanned {report['questions_scanned']} questions in "
          f"{len(report['files_scanned'])} files")
    print("counts by category:")
    for cat, n in sorted(report["counts"].items(), key=lambda kv: -kv[1]):
        print(f"  {cat:30s} {n}")
    print(f"json: {json_path.relative_to(REPO_ROOT)}")
    print(f"html: {html_path.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    main()
