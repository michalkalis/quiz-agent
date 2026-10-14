"""Feasibility check: can a taste-conditioned Claude grader predict the founder's
blind fun ratings on questions it never saw? (claude.dev eval guidance, 2026-09)

Baseline to beat: every earlier LLM grader reached Spearman <= 0.24 (#165 D21,
#166 D21b, #201 casual player, #203 cliche). Gate for a full hillclimb:
pooled test Spearman >= 0.40 with the 95 % CI lower bound above 0.24.

Runs on the Claude Code subscription (`claude -p`, API keys scrubbed), founder
2026-10-14: "zo subscription, nie cez api kredity".

    python3 run_eval.py run      # grade the test split twice (16 calls)
    python3 run_eval.py score    # metrics from results/*.json
"""

from __future__ import annotations

import hashlib
import json
import os
import random
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).parent
RATINGS = HERE.parents[0] / "prompt-ab-2026-10-14" / "founder_ratings_all.json"
RESULTS = HERE / "results"
BATCH = 20
RUNS = 2
FEWSHOT_PER_BAND = 12
MODEL = os.environ.get("GRADER_MODEL", "opus")

CLAIMS = {
    "russia_war_politics": "Is about Russia, a war, or current politics.",
    "answer_is_year": "The answer is a year, a date or a bare number.",
    "obscure_person": "Centres on a person most adults have never heard of.",
    "expected_comparison": "Asks for the biggest/first/most of an obvious set, so the answer is predictable.",
    "school_fact": "Feels like a school test question rather than a fun fact.",
    "surprising_twist": "The answer reveals something counterintuitive the player didn't expect.",
    "tellable": "Something you'd retell to a friend after the game.",
    "guessable": "A casual adult has a real chance to reach the answer by reasoning.",
}

TASTE = """You predict how one specific player, the founder of a voice trivia app
(Slovak, plays in English/Slovak/Czech, often while driving), rates quiz questions
for FUN on 1-10. His ratings so far: he loves surprising, tellable facts with a
twist and questions he can reason his way into; he dislikes Russia/war/politics,
years and bare numbers as answers, people nobody has heard of, predictable
"biggest/first" comparisons, and school-textbook questions. Ratings are blind and
independent of correctness. Calibrate on the rated examples below: they are his
real scores (and his own notes, in Slovak, where he left one)."""


def load() -> list[dict]:
    rows = [r for r in json.loads(RATINGS.read_text()) if r.get("score_10") is not None]
    for r in rows:
        r["score"] = max(1.0, min(10.0, float(r["score_10"])))
        r["id"] = hashlib.sha1(r["question"].encode()).hexdigest()[:10]
        r["split"] = "test" if int(r["id"], 16) % 3 == 0 else "train"
    return rows


def is_founder_note(note: str | None) -> bool:
    # Founder notes are Slovak, unaccented; LLM-written notes in older rounds are English.
    return bool(note) and re.search(r"\b(je|sa|ze|neviem|otazk\w*|zaujim\w*|nie)\b", note) is not None


def fewshot(train: list[dict]) -> str:
    rng = random.Random(14)
    bands = [(1, 5), (6, 7), (8, 8.99), (9, 10)]
    picked = []
    for lo, hi in bands:
        band = [r for r in train if lo <= r["score"] <= hi]
        picked += rng.sample(band, min(FEWSHOT_PER_BAND, len(band)))
    rng.shuffle(picked)
    lines = []
    for r in picked:
        note = f' | note: "{r["note"][:160]}"' if is_founder_note(r.get("note")) else ""
        lines.append(f'- [{r["language"]}] Q: {r["question"]} A: {r["answer"]} -> {r["score"]:g}{note}')
    return "\n".join(lines)


def prompt(items: list[dict], examples: str) -> str:
    claims = "\n".join(f'- "{k}": {v}' for k, v in CLAIMS.items())
    qs = "\n".join(f'{i["id"]}. [{i["language"]}] Q: {i["question"]} A: {i["answer"]}' for i in items)
    return f"""{TASTE}

Rated examples:
{examples}

For each question below, answer every claim true/false, then predict his score
(1-10, one decimal allowed). Reply with ONLY a JSON array, one object per
question: {{"id": "...", "claims": {{{", ".join(f'"{k}": bool' for k in CLAIMS)}}}, "score": number}}.

Claims:
{claims}

Questions:
{qs}"""


def call_claude(text: str) -> list[dict]:
    env = {k: v for k, v in os.environ.items() if k not in (
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX")}
    out = subprocess.run(
        ["claude", "-p", "--model", MODEL, "--output-format", "json", "--tools", "",
         "--disable-slash-commands", "--strict-mcp-config"],
        # Outside the repo so no project CLAUDE.md / memory reaches the grader.
        input=text, capture_output=True, text=True, env=env, timeout=900, check=True,
        cwd=tempfile.gettempdir(),
    )
    envelope = json.loads(out.stdout)
    if envelope.get("is_error"):
        raise RuntimeError(envelope.get("result"))
    body = envelope["result"]
    return json.loads(body[body.index("["): body.rindex("]") + 1])


def run() -> None:
    rows = load()
    train = [r for r in rows if r["split"] == "train"]
    test = [r for r in rows if r["split"] == "test"]
    examples = fewshot(train)
    RESULTS.mkdir(exist_ok=True)
    print(f"train {len(train)} test {len(test)} model {MODEL}")
    for run_no in range(1, RUNS + 1):
        order = test[:]
        random.Random(run_no).shuffle(order)
        for b in range(0, len(order), BATCH):
            path = RESULTS / f"run{run_no}-b{b // BATCH:02d}.json"
            if path.exists():
                continue
            batch = order[b:b + BATCH]
            graded = call_claude(prompt(batch, examples))
            missing = {i["id"] for i in batch} - {g["id"] for g in graded}
            if missing:
                raise RuntimeError(f"{path.name}: grader skipped {sorted(missing)}")
            path.write_text(json.dumps(graded, indent=1))
            print(f"  {path.name} ok")


def ranks(xs: list[float]) -> list[float]:
    order = sorted(range(len(xs)), key=xs.__getitem__)
    r = [0.0] * len(xs)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and xs[order[j + 1]] == xs[order[i]]:
            j += 1
        for k in range(i, j + 1):
            r[order[k]] = (i + j) / 2
        i = j + 1
    return r


def spearman(a: list[float], b: list[float]) -> float:
    ra, rb = ranks(a), ranks(b)
    ma, mb = sum(ra) / len(ra), sum(rb) / len(rb)
    cov = sum((x - ma) * (y - mb) for x, y in zip(ra, rb))
    va = sum((x - ma) ** 2 for x in ra) ** 0.5
    vb = sum((y - mb) ** 2 for y in rb) ** 0.5
    return cov / (va * vb) if va and vb else 0.0


def score() -> None:
    rows = {r["id"]: r for r in load() if r["split"] == "test"}
    preds: dict[int, dict[str, dict]] = {}
    for f in sorted(RESULTS.glob("run*-b*.json")):
        run_no = int(f.name[3])
        for g in json.loads(f.read_text()):
            preds.setdefault(run_no, {})[g["id"]] = g
    ids = [i for i in rows if all(i in p for p in preds.values())]
    truth = [rows[i]["score"] for i in ids]
    mean_pred = [sum(p[i]["score"] for p in preds.values()) / len(preds) for i in ids]

    rng = random.Random(0)
    boot = sorted(
        spearman([truth[k] for k in s], [mean_pred[k] for k in s])
        for s in ([rng.randrange(len(ids)) for _ in ids] for _ in range(2000))
    )
    print(f"n={len(ids)} runs={len(preds)}")
    print(f"pooled Spearman {spearman(truth, mean_pred):.3f}  95% CI [{boot[50]:.3f}, {boot[1949]:.3f}]")
    if len(preds) >= 2:
        a, b = preds[1], preds[2]
        print(f"run-to-run Spearman (grader noise) {spearman([a[i]['score'] for i in ids], [b[i]['score'] for i in ids]):.3f}")

    by_src: dict[str, list[int]] = {}
    for k, i in enumerate(ids):
        by_src.setdefault(rows[i]["source"], []).append(k)
    weighted = [(len(ks), spearman([truth[k] for k in ks], [mean_pred[k] for k in ks]))
                for ks in by_src.values() if len(ks) >= 8]
    if weighted:
        w = sum(n for n, _ in weighted)
        print(f"within-round Spearman (rounds with >=8 test items, n={w}) {sum(n * s for n, s in weighted) / w:.3f}")

    cut = sorted(mean_pred)[int(len(ids) * 0.3)]
    low = [k for k in range(len(ids)) if truth[k] <= 5]
    top = [k for k in range(len(ids)) if truth[k] >= 9]
    flagged = {k for k in range(len(ids)) if mean_pred[k] < cut}
    print(f"bottom-30% filter: catches {sum(k in flagged for k in low)}/{len(low)} of his <=5, "
          f"drops {sum(k in flagged for k in top)}/{len(top)} of his >=9")

    for c in CLAIMS:
        vals = [float(sum(p[i]["claims"].get(c, False) for p in preds.values())) for i in ids]
        print(f"  claim {c:22s} Spearman vs his score {spearman(truth, vals):+.3f}  (true in {sum(v > 0 for v in vals)})")


if __name__ == "__main__":
    {"run": run, "score": score}[sys.argv[1]]()
