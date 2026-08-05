"""Blind raw-generation sample across three Bedrock models (2026-08-05).

Throwaway comparison script. It reuses the REAL generation prompt by calling
``AdvancedQuestionGenerator._generate_batch`` directly — that seam builds the
v2_cot prompt, invokes the generation LLM, parses and tags the questions, and
touches nothing else. Everything downstream that costs OpenRouter money
(critique, best-of-N pairwise selection, fact verification, judging/scoring,
dedup-against-corpus, DB persistence) lives in ``generate_questions`` and the
pipeline stages, and is deliberately never entered here. ``critique_llm`` is
dropped right after construction so no critique call is even possible.

Runs on the Fly machine (AWS credentials are Fly secrets only):

    cat scripts/bedrock_raw_sample.py | fly ssh console -a quiz-pack-api \\
        --machine <id> -C "sh -c 'cat > /tmp/x.py'"
    fly ssh console -a quiz-pack-api --machine <id> -C "python /tmp/x.py"

Prints both markdown documents to stdout between markers; the caller writes
them into docs/research/ locally.
"""

import asyncio
import os
import random
import sys
import time

sys.path.insert(0, "/app")
if os.path.isdir("/app"):
    os.chdir("/app")

from app.generation.advanced_generator import AdvancedQuestionGenerator  # noqa: E402

MODELS = [
    "bedrock:zai.glm-5",
    "bedrock:moonshotai.kimi-k2.5",
    "bedrock:deepseek.v3.2",
]

PER_MODEL = 8
BATCH = 4
SEED = 20260805

# Same brief + same params for every model.
BRIEF = dict(
    difficulty=None,  # mixed spread
    topics=["history", "science", "geography", "arts", "sports", "technology"],
    categories=None,
    question_type="text",
    excluded_topics=None,
    avoid_questions=None,
    user_bad_examples=None,
    source_facts=None,
    mcq_patterns=None,
    mcq_emphasis=False,
    open_shape=False,
)


def _is_throttle(exc: Exception) -> bool:
    text = f"{type(exc).__name__}: {exc}"
    return any(
        marker in text
        for marker in ("Throttl", "TooManyRequests", "ServiceUnavailable", "429")
    )


async def _batch_with_retry(gen, count, label):
    delay = 10
    for attempt in range(1, 6):
        try:
            return await gen._generate_batch(count=count, **BRIEF)
        except Exception as exc:  # noqa: BLE001 - throwaway script
            if _is_throttle(exc) and attempt < 5:
                print(
                    f"  [{label}] throttled (attempt {attempt}), "
                    f"sleeping {delay}s: {exc}",
                    file=sys.stderr,
                )
                time.sleep(delay)
                delay *= 2
                continue
            print(f"  [{label}] FAILED: {type(exc).__name__}: {exc}", file=sys.stderr)
            return []
    return []


async def main():
    results = {}
    for model in MODELS:
        gen = AdvancedQuestionGenerator(generation_model=model)
        gen.critique_llm = None  # no critique path may exist
        got = []
        # Top-up loop, not a fixed batch count: a model can return fewer
        # questions than asked (short batch) or an unparseable body, and the
        # comparison is only fair at equal N.
        for _attempt in range(4):
            want = min(BATCH, PER_MODEL - len(got))
            if want <= 0:
                break
            questions = await _batch_with_retry(gen, want, model)
            got.extend(questions)
            print(f"  [{model}] batch -> {len(questions)} (total {len(got)})",
                  file=sys.stderr)
            time.sleep(5)
        results[model] = got[:PER_MODEL]
        if len(results[model]) < PER_MODEL:
            print(
                f"  [{model}] SHORT: {len(results[model])}/{PER_MODEL}",
                file=sys.stderr,
            )

    rows = [(m, q) for m, qs in results.items() for q in qs]
    random.Random(SEED).shuffle(rows)

    blind = [
        "# Raw-generation blind sample — 2026-08-05",
        "",
        "Raw first-pass generation output. No critique, no quality gate, no "
        "scoring, nothing persisted. Rate each question 1-10 in the Rating "
        "column (question quality: interest, fairness, phrasing, answerability).",
        "",
    ]
    for i, (_model, q) in enumerate(rows, 1):
        answer = q.correct_answer
        if isinstance(answer, list):
            answer = " / ".join(str(a) for a in answer)
        blind.append(f"### #{i}")
        blind.append("")
        blind.append(f"**Q:** {q.question}")
        blind.append("")
        blind.append(f"**A:** {answer}")
        if q.explanation:
            blind.append("")
            blind.append(f"_{q.explanation}_")
        blind.append("")
        blind.append(f"**Topic:** {q.topic} · **Difficulty:** {q.difficulty}")
        blind.append("")
        blind.append("**Rating (1-10):**")
        blind.append("")
    blind_md = "\n".join(blind)

    key = [
        "# Bedrock raw-generation blind sample — KEY (2026-08-05)",
        "",
        "| # | Model |",
        "|---|-------|",
    ]
    for i, (model, _q) in enumerate(rows, 1):
        key.append(f"| {i} | `{model}` |")
    key.append("")
    key.append("## Counts")
    key.append("")
    key.append("| Model | Questions |")
    key.append("|-------|-----------|")
    for model in MODELS:
        key.append(f"| `{model}` | {len(results[model])} / {PER_MODEL} |")
    key_md = "\n".join(key)

    print("===BLIND_START===")
    print(blind_md)
    print("===BLIND_END===")
    print("===KEY_START===")
    print(key_md)
    print("===KEY_END===")


if __name__ == "__main__":
    asyncio.run(main())
