"""Standalone fact sourcing for the #167 entertainment pilot (D4).

Sourcing runs as its OWN step, BEFORE generation: `generate_pack.py
--dump-facts` writes the fact file only *after* a successful generation run,
so it cannot hand facts to the run that needs them. This script writes the
same `{"topics": [...], "facts": [...]}` shape that
`generate_pack._FactsFileSourcingStage` reads back via `--facts-file`.

Deliberate deviations from the D21b news recipe (`run_d21b_arms.py:_source`),
both locked in D4:
- **Wikipedia stays ON.** D21b disabled it because a weekly news window makes
  encyclopedia hits pure noise; #167 sources *post-cutoff settled facts*
  (rosters, releases, awards), which Wikipedia carries well.
- **No news mode.** `ENABLE_NEWS_SOURCING` is never set or read here — recency
  is carried by the locked topic list, not by the provider's news narrowing.

OpenTriviaDB is off: it serves canned trivia, which by construction predates
the model cutoff and cannot contribute a post-cutoff fact.

A thin yield exits 1 with a per-topic tally rather than writing a small fact
file that would silently starve generation downstream.

Usage (from apps/quiz-pack-api/, .env loaded for TAVILY_API_KEY):

    uv run --no-sync python scripts/source_facts.py \
        --topics "music producers and their artists,2026 album releases" \
        --out facts_167.json
"""

import argparse
import asyncio
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

# D4 thin-yield gate: fewer than this many facts across all topics and the run
# fails loud. The pilot needs ~30 questions to survive the post-cutoff filter,
# and generation drops facts it cannot ground.
MIN_FACTS = 40

# Surplus per topic (same rationale as run_d21b_arms.py:_source): sourced
# pages are boilerplate-heavy, so ask for well above the per-topic share the
# gate demands.
PER_TOPIC_BUDGET = 8


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--topics",
        required=True,
        help="comma-separated topic list (same shape as generate_pack.py --topics)",
    )
    parser.add_argument(
        "--out",
        required=True,
        help="path to write the fact file consumed by generate_pack.py --facts-file",
    )
    return parser.parse_args(argv)


async def _run(args: argparse.Namespace) -> int:
    from app.sourcing.fact_sourcer import FactSourcer

    topics = [t.strip() for t in args.topics.split(",") if t.strip()]
    if not topics:
        print("--topics resolved to an empty topic list", file=sys.stderr)
        return 1

    # Wikipedia ON, OpenTriviaDB OFF, news mode untouched — see module docstring.
    sourcer = FactSourcer(enable_opentdb=False)
    batch = await sourcer.gather_facts(
        count=PER_TOPIC_BUDGET * len(topics), topics=topics
    )

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    payload = {"topics": topics, "facts": [f.to_dict() for f in batch.facts]}
    out_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")

    print(f"{out_path}: {len(batch.facts)} facts across {len(topics)} topics")
    if len(batch.facts) < MIN_FACTS:
        _print_thin_yield(batch.facts_per_topic, len(batch.facts), len(topics))
        return 1
    return 0


def _print_thin_yield(tally: dict[str, int], total: int, topic_count: int) -> None:
    """Name the topics that starved, so the retry can rephrase exactly those."""
    share = math.ceil(MIN_FACTS / topic_count)
    ascending = sorted(tally.items(), key=lambda kv: (kv[1], kv[0]))
    print(f"THIN YIELD: {total} facts < {MIN_FACTS} required — per-topic tally:")
    for topic, count in ascending:
        print(f"  {count:4d}  {topic}")
    # A total below MIN_FACTS guarantees at least one topic under its share,
    # so this list is never empty when the gate fires.
    weak = [t for t, c in ascending if c < share]
    print(f"weakest topics (< {share} facts each): {', '.join(weak)}")


def main(argv: list[str] | None = None) -> int:
    return asyncio.run(_run(_parse_args(argv)))


if __name__ == "__main__":
    raise SystemExit(main())
