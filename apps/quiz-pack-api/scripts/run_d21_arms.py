"""D21 experiment round — raw generation across arms (joint review 2026-08-09).

Generates RAW questions per arm: no critique, no best-of-N, no duels, no
gates, no verification, no judges — the founder rates everything, then the
same questions are replayed through each pipeline layer (replay_d21_layers.py)
to compute per-layer correlation with human ratings (D21/D27).

Usage (from apps/quiz-pack-api/, .env loaded by the factory):

    uv run --no-sync python scripts/run_d21_arms.py source
    uv run --no-sync python scripts/run_d21_arms.py generate [--arm NAME] [--out-dir DIR]

`source` dumps two fact files (shared grounded facts + entertainment news
facts) so every grounded arm generates from IDENTICAL facts. `generate` runs
all arms (or one) and writes `<arm>.json` + `<arm>.usage.json` + manifest.
A failed arm is reported loudly and NEVER silently substituted (founder rule).
"""

import argparse
import asyncio
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

DEFAULT_OUT_DIR = (
    Path(__file__).resolve().parents[3] / "docs" / "testing" / "runs"
    / "d21-round-2026-08-15"
)

# One axis changes at a time (see docs/issues/issue-164-d21-experiment-round.md):
# prompts on fixed Kimi (grounded, shared facts); personas on fixed Kimi+direct;
# models on the fixed new direct prompt. Kimi K2.5 = current prod gen model.
KIMI = "bedrock:moonshotai.kimi-k2.5"
PER_ARM = 8
BATCH = 4

SHARED_TOPICS = [
    "animal biology oddities",
    "space exploration",
    "everyday food science",
    "world geography surprises",
    "history of inventions",
    "money and trade",
    "the human body",
    "sports history",
]

NEWS_TOPICS = [
    "music industry recent news",
    "famous music producers and their artists",
    "film and streaming industry recent events",
    "pop culture recent moments",
]

ARMS = {
    # prompt axis — grounded, Kimi, shared facts
    "g-v3": dict(mode="grounded", model=KIMI, prompt="question_generation_v3_fact_first.md"),
    "g-v5free": dict(mode="grounded", model=KIMI, prompt="question_generation_v5_free.md"),
    "g-v6free": dict(mode="grounded", model=KIMI, prompt="question_generation_v6_free.md"),
    # persona axis — direct, Kimi, new direct prompt (D23: a, b, d=no persona)
    "d-base": dict(mode="direct", model=KIMI, prompt="question_generation_direct.md"),
    "d-persona-a": dict(mode="direct", model=KIMI, prompt="question_generation_direct_persona_a.md"),
    "d-persona-b": dict(mode="direct", model=KIMI, prompt="question_generation_direct_persona_b.md"),
    # model axis — direct, new direct prompt (Kimi covered by d-base)
    "d-gemini": dict(mode="direct", model="gemini-3.1-pro-preview", prompt="question_generation_direct.md"),
    "d-deepseek": dict(mode="direct", model="bedrock:deepseek.v3.2", prompt="question_generation_direct.md"),
    "d-opus": dict(mode="direct", model="claude-opus-5", prompt="question_generation_direct.md"),
    "d-fable": dict(mode="direct", model="claude-fable-5", prompt="question_generation_direct.md"),
    # entertainment/news arm (kandidát 17, #76 F-3b infra) — own topics/facts
    "e-news": dict(mode="news", model=KIMI, prompt=None, categories=["entertainment"]),
}

SHARED_FACTS = "facts_shared.json"
NEWS_FACTS = "facts_news.json"


def _prompts_dir() -> Path:
    return Path(__file__).resolve().parents[1] / "prompts"


async def _gather(topics: list[str], news: bool, out_path: Path) -> None:
    from app.sourcing.fact_sourcer import FactSourcer

    if news:
        os.environ["ENABLE_NEWS_SOURCING"] = "1"
        # News facts must come from live web search only — Wikipedia/OpenTDB
        # would pollute the recency premise of the entertainment arm.
        sourcer = FactSourcer(enable_wikipedia=False, enable_opentdb=False)
    else:
        os.environ.pop("ENABLE_NEWS_SOURCING", None)
        # OpenTDB off: pseudo-facts ("the answer to X is Y") must not enter
        # generation (joint-review D6; rewriter not built yet).
        sourcer = FactSourcer(enable_opentdb=False)
    # Facts in surplus (D5): news pages carry boilerplate the generator must
    # skip past, so the news pool gets double the per-topic budget.
    per_topic = 6 if news else 3
    batch = await sourcer.gather_facts(count=per_topic * len(topics), topics=topics)
    payload = {"topics": topics, "facts": [f.to_dict() for f in batch.facts]}
    out_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    print(f"{out_path.name}: {len(batch.facts)} facts across {len(topics)} topics")
    if len(batch.facts) < len(topics) * 2:
        print("WARNING: thin fact yield — grounded arms may starve", file=sys.stderr)


def _load_facts(path: Path):
    from app.sourcing.models import Fact

    payload = json.loads(path.read_text())
    return payload["topics"], [Fact.from_dict(f) for f in payload["facts"]]


def _is_throttle(exc: Exception) -> bool:
    text = f"{type(exc).__name__}: {exc}"
    return any(m in text for m in ("Throttl", "TooManyRequests", "ServiceUnavailable", "429"))


async def _batch_with_retry(gen, count: int, label: str, brief: dict):
    delay = 10
    for attempt in range(1, 6):
        try:
            return await gen._generate_batch(count=count, **brief)
        except Exception as exc:  # noqa: BLE001 — experiment harness
            if _is_throttle(exc) and attempt < 5:
                print(f"  [{label}] throttled (attempt {attempt}), sleep {delay}s", file=sys.stderr)
                time.sleep(delay)
                delay *= 2
                continue
            print(f"  [{label}] FAILED: {type(exc).__name__}: {exc}", file=sys.stderr)
            raise
    return []


async def _run_arm(name: str, cfg: dict, out_dir: Path) -> dict:
    from app.generation.advanced_generator import AdvancedQuestionGenerator
    from app.generation.prompt_builder import PromptBuilder
    from app import llm_usage
    from quiz_shared.llm import factory as llm_factory

    recorder = llm_usage.UsageRecorder()
    llm_factory.set_usage_handler(llm_usage.UsageCallbackHandler(recorder))
    try:
        if cfg["mode"] == "grounded":
            gen = AdvancedQuestionGenerator(
                generation_model=cfg["model"], fact_first_template=cfg["prompt"]
            )
            topics, facts = _load_facts(out_dir / SHARED_FACTS)
            categories = None
        elif cfg["mode"] == "news":
            gen = AdvancedQuestionGenerator(generation_model=cfg["model"])
            topics, facts = _load_facts(out_dir / NEWS_FACTS)
            categories = cfg["categories"]
        else:  # direct — swap the fact-free builder for the new direct prompt
            gen = AdvancedQuestionGenerator(generation_model=cfg["model"])
            gen.prompt_builder = PromptBuilder(
                template_path=str(_prompts_dir() / cfg["prompt"])
            )
            gen.prompt_version = cfg["prompt"].removesuffix(".md")
            topics, facts, categories = SHARED_TOPICS, None, None
        gen.critique_llm = None  # raw arms: no critique path may exist

        brief = dict(
            difficulty=None,
            topics=topics,
            categories=categories,
            question_type="text",
            excluded_topics=None,
            avoid_questions=None,
            user_bad_examples=None,
            source_facts=facts,
            mcq_patterns=None,
            mcq_emphasis=False,
            open_shape=False,
        )

        got = []
        for _ in range(4):
            want = min(BATCH, PER_ARM - len(got))
            if want <= 0:
                break
            got.extend(await _batch_with_retry(gen, want, name, brief))
            print(f"  [{name}] total {len(got)}", file=sys.stderr)
        got = got[:PER_ARM]

        payload = []
        for q in got:
            entry = q.model_dump(mode="json")
            entry["review_status"] = "pending_review"
            payload.append(entry)
        (out_dir / f"{name}.json").write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
        )
        (out_dir / f"{name}.usage.json").write_text(
            json.dumps(recorder.summary(), ensure_ascii=False, indent=2) + "\n"
        )
        status = "ok" if len(got) == PER_ARM else f"SHORT {len(got)}/{PER_ARM}"
        return {"arm": name, "count": len(got), "status": status}
    finally:
        llm_factory.set_usage_handler(None)


async def _generate(args) -> int:
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    names = [args.arm] if args.arm else list(ARMS)
    unknown = [n for n in names if n not in ARMS]
    if unknown:
        raise SystemExit(f"unknown arm(s): {unknown}")

    results = []
    for name in names:
        print(f"== arm {name} ({ARMS[name]['mode']}, {ARMS[name]['model']})")
        try:
            results.append(await _run_arm(name, ARMS[name], out_dir))
        except Exception as exc:  # noqa: BLE001 — never substitute, report loudly
            results.append({"arm": name, "count": 0, "status": f"FAILED: {exc}"})

    manifest = {
        "round": "d21-2026-08-15",
        "per_arm": PER_ARM,
        "shared_topics": SHARED_TOPICS,
        "news_topics": NEWS_TOPICS,
        "arms": {n: {**ARMS[n]} for n in names},
        "results": results,
        "llm_gateway": os.environ.get("LLM_GATEWAY", "direct"),
    }
    (out_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
    )
    print(json.dumps(results, indent=2))
    failed = [r for r in results if not str(r["status"]).startswith(("ok", "SHORT"))]
    return 1 if failed else 0


async def _source(args) -> int:
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    await _gather(SHARED_TOPICS, news=False, out_path=out_dir / SHARED_FACTS)
    await _gather(NEWS_TOPICS, news=True, out_path=out_dir / NEWS_FACTS)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    for cmd in ("source", "generate"):
        p = sub.add_parser(cmd)
        p.add_argument("--out-dir", default=str(DEFAULT_OUT_DIR))
        if cmd == "generate":
            p.add_argument("--arm", default=None, help="run a single arm")
    args = parser.parse_args()
    return asyncio.run(_source(args) if args.cmd == "source" else _generate(args))


if __name__ == "__main__":
    raise SystemExit(main())
