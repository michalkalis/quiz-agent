"""D21b experiment round — raw generation, canonical config (issue-164 follow-up).

Founder-approved parameters (in-session 2026-08-18, total revised 150 -> 100
same day): 100 published questions =
70 f-base (Fable 5 + direct v1) + 20 e-news-f (Fable 5) + 10 e-news-k (Kimi),
both e-news arms on the reprompted entertainment v2 prompt. Arms overgenerate
~25% so the answer-first dedupe (dedupe_d21b.py) can drop repeats and still
hit the publish targets. Raw generation: no critique/duels/gates/judges.

The two e-news arms get DISJOINT fact slices (seeded 2:1 split) so shared
facts cannot manufacture cross-arm duplicates that dedupe would then eat out
of the publish targets.

Usage (from apps/quiz-pack-api/, .env loaded by the factory; Fable/Opus need
LLM_GATEWAY=openrouter — Bedrock Claude is locked):

    uv run --no-sync python scripts/run_d21b_arms.py source
    uv run --no-sync python scripts/run_d21b_arms.py generate [--arm NAME] [--out-dir DIR]

A failed arm is reported loudly and NEVER silently substituted (founder rule).
"""

import argparse
import asyncio
import json
import os
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

DEFAULT_OUT_DIR = (
    Path(__file__).resolve().parents[3] / "docs" / "testing" / "runs"
    / "d21b-round-2026-08-18"
)

KIMI = "bedrock:moonshotai.kimi-k2.5"
FABLE = "claude-fable-5"
BATCH = 4
SEED = 20260818

# Broad general-trivia pool for the volume arm; rotated in slices of 4 per
# batch so repeated batches don't converge on each topic's single best fact.
DIRECT_TOPICS = [
    "animal biology oddities",
    "space exploration",
    "everyday food science",
    "world geography surprises",
    "history of inventions",
    "money and trade",
    "the human body",
    "sports history",
    "ocean and deep sea mysteries",
    "weather and natural phenomena",
    "ancient civilizations daily life",
    "famous landmarks and their secrets",
    "transport and aviation firsts",
    "music history milestones",
    "classic films and pop culture history",
    "plants and fungi oddities",
    "chemistry in everyday life",
    "maps and borders quirks",
    "records and extremes in nature",
    "technology origins and firsts",
    "art and artists surprises",
    "games and toys history",
    "famous rulers and royal quirks",
    "engineering marvels",
]

# Reprompt brief (founder 2026-08-12/18): concrete facts, famous names, the
# music-producer example front and centre.
NEWS_TOPICS = [
    "famous music producers and the artists they make hits for",
    "biggest music artists recent releases and chart records",
    "blockbuster films and famous directors recent releases",
    "hit TV and streaming series recent seasons and finales",
    "major music and film awards recent winners",
    "famous artist collaborations and reunions recent",
]

ENTERTAINMENT_V2 = "question_generation_entertainment_v2.md"

# target = raw questions to generate (~25-30% over the publish count).
ARMS = {
    "f-base": {
        "mode": "direct", "model": FABLE,
        "prompt": "question_generation_direct.md",
        "target": 88, "publish": 70,
    },
    "e-news-f": {
        "mode": "news", "model": FABLE, "prompt": ENTERTAINMENT_V2,
        "categories": ["entertainment"], "target": 26, "publish": 20,
    },
    "e-news-k": {
        "mode": "news", "model": KIMI, "prompt": ENTERTAINMENT_V2,
        "categories": ["entertainment"], "target": 13, "publish": 10,
    },
}

NEWS_FACTS = "facts_news.json"


def _prompts_dir() -> Path:
    return Path(__file__).resolve().parents[1] / "prompts"


async def _source(args) -> int:
    from app.sourcing.fact_sourcer import FactSourcer

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    os.environ["ENABLE_NEWS_SOURCING"] = "1"
    # Live web search only — Wikipedia/OpenTDB would pollute recency (D21 rule).
    sourcer = FactSourcer(enable_wikipedia=False, enable_opentdb=False)
    per_topic = 8  # surplus (D5): boilerplate-heavy news pages + two arms to feed
    batch = await sourcer.gather_facts(
        count=per_topic * len(NEWS_TOPICS), topics=NEWS_TOPICS
    )
    payload = {"topics": NEWS_TOPICS, "facts": [f.to_dict() for f in batch.facts]}
    (out_dir / NEWS_FACTS).write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    )
    print(f"{NEWS_FACTS}: {len(batch.facts)} facts across {len(NEWS_TOPICS)} topics")
    if len(batch.facts) < 40:
        print("WARNING: thin news yield — e-news arms may starve", file=sys.stderr)
    return 0


def _news_fact_slices(out_dir: Path):
    """Seeded disjoint 2:1 split of the news facts between the e-news arms."""
    from app.sourcing.models import Fact

    payload = json.loads((out_dir / NEWS_FACTS).read_text())
    facts = [Fact.from_dict(f) for f in payload["facts"]]
    order = list(range(len(facts)))
    random.Random(SEED).shuffle(order)
    cut = len(order) * 2 // 3
    return payload["topics"], {
        "e-news-f": [facts[i] for i in sorted(order[:cut])],
        "e-news-k": [facts[i] for i in sorted(order[cut:])],
    }


def _is_throttle(exc: Exception) -> bool:
    text = f"{type(exc).__name__}: {exc}"
    return any(m in text for m in ("Throttl", "TooManyRequests", "ServiceUnavailable", "429", "529", "Overloaded"))


async def _batch_with_retry(gen, count: int, label: str, brief: dict):
    delay = 10
    for attempt in range(1, 6):
        try:
            return await gen._generate_batch(count=count, **brief)
        except Exception as exc:
            if _is_throttle(exc) and attempt < 5:
                print(f"  [{label}] throttled (attempt {attempt}), sleep {delay}s", file=sys.stderr)
                await asyncio.sleep(delay)
                delay *= 2
                continue
            print(f"  [{label}] FAILED: {type(exc).__name__}: {exc}", file=sys.stderr)
            raise
    return []


async def _run_arm(name: str, cfg: dict, out_dir: Path) -> dict:
    from app import llm_usage
    from app.generation.advanced_generator import AdvancedQuestionGenerator
    from app.generation.prompt_builder import PromptBuilder
    from quiz_shared.llm import factory as llm_factory

    recorder = llm_usage.UsageRecorder()
    llm_factory.set_usage_handler(llm_usage.UsageCallbackHandler(recorder))
    try:
        gen = AdvancedQuestionGenerator(generation_model=cfg["model"])
        # OpenRouter reserves the model's FULL output cap (64k for Fable)
        # against remaining credit per request → 402 on a low balance even
        # though a 4-question batch needs ~4-8k tokens. Cap explicitly.
        gen.generation_llm = llm_factory.chat_openai(
            cfg["model"], temperature=0.8, max_tokens=16384
        )
        if cfg["mode"] == "news":
            # v2 reprompt rides the category dispatch: replace the registered
            # entertainment builder (v2 keeps every required fact-first
            # placeholder, so injection below is unchanged).
            gen.category_prompt_builders["entertainment"] = PromptBuilder(
                template_path=str(_prompts_dir() / cfg["prompt"])
            )
            if cfg.get("facts_file"):
                # top-up path: a dedicated fresh-facts file for this arm only
                # (the seeded 2:1 slice of facts_news.json stays untouched)
                from app.sourcing.models import Fact

                payload = json.loads((out_dir / cfg["facts_file"]).read_text())
                facts = [Fact.from_dict(f) for f in payload["facts"]]
            else:
                _, slices = _news_fact_slices(out_dir)
                facts = slices[name]
            categories, topics = cfg["categories"], NEWS_TOPICS
        else:  # direct
            gen.prompt_builder = PromptBuilder(
                template_path=str(_prompts_dir() / cfg["prompt"])
            )
            gen.prompt_version = cfg["prompt"].removesuffix(".md")
            facts, categories, topics = None, None, DIRECT_TOPICS
        gen.critique_llm = None  # raw arms: no critique path may exist

        got = []
        target = cfg["target"]
        max_calls = (target // BATCH + 1) * 2  # loud stop, never an endless loop
        for i in range(max_calls):
            want = min(BATCH, target - len(got))
            if want <= 0:
                break
            if cfg["mode"] == "direct":
                # rotate a 4-topic window so batches spread across the pool
                start = (i * BATCH) % len(topics)
                batch_topics = [topics[(start + j) % len(topics)] for j in range(4)]
            else:
                batch_topics = topics
            # avoid_questions accumulates what this arm already wrote —
            # the cheapest anti-duplicate lever (capped to bound prompt growth)
            brief = {
                "difficulty": None,
                "topics": batch_topics,
                "categories": categories,
                "question_type": "text",
                "excluded_topics": None,
                "avoid_questions": [q.question for q in got][-80:] or None,
                "user_bad_examples": None,
                "source_facts": facts,
                "mcq_patterns": None,
                "mcq_emphasis": False,
                "open_shape": False,
            }
            got.extend(await _batch_with_retry(gen, want, name, brief))
            print(f"  [{name}] total {len(got)}/{target}", file=sys.stderr)
        got = got[:target]

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
        status = "ok" if len(got) == target else f"SHORT {len(got)}/{target}"
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
    if args.target is not None and not args.arm:
        raise SystemExit("--target requires --arm (single-arm top-up runs only)")

    results = []
    for name in names:
        cfg = dict(ARMS[name])
        if args.target is not None:
            cfg["target"] = args.target
        if args.facts_file:
            if cfg["mode"] != "news":
                raise SystemExit("--facts-file only applies to news arms")
            cfg["facts_file"] = args.facts_file
        print(f"== arm {name} ({cfg['mode']}, {cfg['model']})")
        try:
            results.append(await _run_arm(name, cfg, out_dir))
        except Exception as exc:  # noqa: BLE001 — never substitute, report loudly
            results.append({"arm": name, "count": 0, "status": f"FAILED: {exc}"})

    manifest = {
        "round": "d21b-2026-08-18",
        "seed": SEED,
        "direct_topics": DIRECT_TOPICS,
        "news_topics": NEWS_TOPICS,
        "arms": {
            n: {**ARMS[n], **({"target": args.target} if args.target is not None else {})}
            for n in names
        },
        "results": results,
        "llm_gateway": os.environ.get("LLM_GATEWAY", "direct"),
    }
    (out_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
    )
    print(json.dumps(results, indent=2))
    failed = [r for r in results if not str(r["status"]).startswith(("ok", "SHORT"))]
    return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    for cmd in ("source", "generate"):
        p = sub.add_parser(cmd)
        p.add_argument("--out-dir", default=str(DEFAULT_OUT_DIR))
        if cmd == "generate":
            p.add_argument("--arm", default=None, help="run a single arm")
            p.add_argument(
                "--target", type=int, default=None,
                help="override raw target for a top-up run (single --arm only; "
                "back up the arm's .json first — the run overwrites it)",
            )
            p.add_argument(
                "--facts-file", default=None,
                help="news-arm top-up: use this facts file (in --out-dir) "
                "instead of the arm's seeded facts_news.json slice",
            )
    args = parser.parse_args()
    return asyncio.run(_source(args) if args.cmd == "source" else _generate(args))


if __name__ == "__main__":
    raise SystemExit(main())
