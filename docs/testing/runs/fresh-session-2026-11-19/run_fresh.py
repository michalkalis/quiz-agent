"""Fresh-entertainment top-up fully on the Claude subscription (founder 2026-11-19:
"priamo pomocou subscription ... aj nejake aktualne pre vsetky jazyky, aj entertainment").

The weekly job (`app.corpus.fresh_topup`) gathers and picks its seeds through the paid
Anthropic API even in a FRESH_TOPUP_SESSION=1 run. Here the seeds come from
`seeds-<lang>.json`, written by session subagents with web search from the job's own
gather and pick prompts (`prompt-*-<lang>.txt`). Everything after that is the job itself:
the same deterministic seed filters (cited URL, page mentions the subject, uk topic
policy, two per subject, fame cut), brief, pinned generation, post-filters and import.

    cd apps/quiz-pack-api && python <this file> --languages uk --count 15 --dry-run

uk additionally gets the Ukrainian house style and the naturalness check (#231).
Run from a shell with the root .env loaded and DATABASE_URL pointing at prod (tunnel).
"""

import json
import os
import sys
from datetime import date
from pathlib import Path

RUN = Path(__file__).parent
os.environ["FRESH_TOPUP_SESSION"] = "1"

from app.corpus import fresh_pins  # noqa: E402

fresh_pins.apply()
if "uk" in " ".join(sys.argv):
    os.environ.update(GEN_HOUSE_STYLE="1", GEN_HOUSE_STYLE_V2="1")
os.environ["NATURALNESS_CHECK"] = "1"

import asyncio  # noqa: E402

from app.corpus import fresh_topup, seed_research  # noqa: E402
from app.corpus.seed_filters import (  # noqa: E402
    cite_filter,
    domestic_share,
    fame_cut,
    subject_cap,
    topic_policy_cut,
)
from app.corpus.seed_page_check import check_pages  # noqa: E402


async def seeds_from_file(lang: str, today: date) -> seed_research.SeedResult:
    items = json.loads((RUN / f"seeds-{lang}.json").read_text())
    result = seed_research.SeedResult(candidates=len(items))
    trusted = [i.get("source_url") for i in items if isinstance(i, dict) and i.get("source_url")]
    seeds, dropped = cite_filter(items, trusted)
    seeds, result.page_check = await check_pages(seeds, None)
    if result.page_check["page_mismatch"]:
        dropped["page_mismatch"] = result.page_check["page_mismatch"]
    seeds = topic_policy_cut(seeds, lang, dropped)
    seeds = subject_cap(seeds, dropped)
    fame_of = seed_research._wiki_fame_lookup(lang, today)
    seeds, fame_checked = await asyncio.to_thread(fame_cut, seeds, fame_of, dropped)
    result.seeds, result.dropped, result.fame_checked = seeds, dropped, fame_checked
    result.domestic_share = domestic_share(lang, seeds)
    return result


# Not fresh_topup.main(): a manual run sends no Sentry check-in or summary event.
args = fresh_topup.parse_args()
deps = fresh_topup.default_deps()
deps.research_seeds = seeds_from_file
summary = asyncio.run(fresh_topup.run(args, deps))
out = RUN / f"summary-{'-'.join(args.languages)}{'-dry' if args.dry_run else ''}.json"
out.write_text(json.dumps(summary, ensure_ascii=False, indent=1, default=str))
print(fresh_topup.fresh_report.compact_summary(summary))
sys.exit(any(e["status"] == "failed" for e in summary["languages"].values()))
