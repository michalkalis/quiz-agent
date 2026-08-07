"""SourcingStage — thin wrapper around FactSourcer (issue #36 task 2.4).

The stage maps `OrderContext` → existing `FactSourcer.gather_facts` arguments
and merges the result back into `ctx.facts`. It derives the topic filter from
order metadata plus a few salient tokens mined from the prompt (#42 task 42.28,
no LLM); beyond that it adds no extra LLM calls. The wrapper exists so
`PackGenerator.run` can compose sourcing alongside the other Phase 2 stages
through a uniform interface.

Cost tracking is coarse on purpose: per the Phase 1 stub seam, Wikipedia
and OpenTriviaDB are free, only Tavily web search is metered. We count one
Tavily call per `gather_facts` invocation that actually used the web-search
source — finer granularity is a Phase 3 concern (#37 cost-cap mid-flight).
"""

from __future__ import annotations

import logging
import math
import re

from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink
from app.sourcing.fact_sourcer import FactSourcer
from app.sourcing.models import FactBatch
from app.sourcing.topic_pool import DEFAULT_TOPIC_COUNT, TopicPool

logger = logging.getLogger(__name__)

# #42 task 42.28 — at most this many salient tokens are mined from the free-text
# prompt to steer sourcing toward what the order actually asked about.
MAX_PROMPT_TOPIC_TOKENS = 3

# Generic words that carry no topic signal. Dropped before deriving topic tokens
# from `ctx.prompt` so "make me 10 quiz questions about Roman emperors" yields
# ["roman", "emperors"], not ["make", "quiz", "questions"]. English-only on
# purpose: this is a no-LLM heuristic, and order prompts are predominantly
# English; a missed stopword only adds a weak topic, never a wrong one.
_PROMPT_STOPWORDS = frozenset(
    {
        "the", "and", "for", "with", "about", "from", "that", "this", "are",
        "was", "were", "has", "have", "had", "you", "your", "our", "their",
        "questions", "question", "quiz", "trivia", "make", "give", "want",
        "some", "any", "all", "into", "out", "who", "what", "when", "where",
        "which", "how", "why", "please", "create", "generate",
        # Filler common to trivia prompts ("X fun facts about Y", "top 10 …")
        # that otherwise eat the token budget before the real topic.
        "fact", "facts", "interesting", "fun", "cool", "top", "best", "most",
        "random",
        # #72 F-1: generic "no real topic" words. Dropping these makes a generic
        # prompt ("general knowledge", "surprise me", "mixed trivia") collapse to
        # no tokens → topics None → SourcingStage samples the curated TopicPool
        # instead of searching "surprising facts about general" (the listicle/
        # military-bias dead end). This stopword set IS the cure for that bias;
        # the pool only decides what to source on once there's no topic. They are
        # genuinely non-topical, so dropping them never costs a real topic
        # ("general relativity" still keeps "relativity").
        "general", "knowledge", "mixed", "mix", "misc", "miscellaneous",
        "various", "variety", "anything", "everything", "surprise", "assorted",
    }
)


class SourcingStage:
    """Calls FactSourcer.gather_facts; stores facts on ctx."""

    name = "sourcing"

    def __init__(
        self,
        fact_sourcer: FactSourcer,
        topic_pool: TopicPool | None = None,
        forced_topics: list[str] | None = None,
    ) -> None:
        self._fact_sourcer = fact_sourcer
        # #72 F-1: dormant by default. Only the CLI/batch path injects a pool
        # (Scope A) — the worker/live path leaves it None so its behavior stays
        # byte-identical until the no-category mode is exposed to the app.
        self._topic_pool = topic_pool
        # #153 experiment lever (CLI --topics): explicit topic list that
        # bypasses both derivation and pool sampling, so every experiment arm
        # sources the SAME topics — topic taste must not proxy for arm.
        self._forced_topics = forced_topics

    async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
        # #153 Phase 0.4 — direct generation: no fact gathering at all. The
        # generator falls back to its non-fact prompt path (source_facts=None)
        # and end-of-pipe verification carries the whole truth burden.
        if ctx.direct_generation:
            ctx.facts = []
            return StageResult(
                info={"direct_generation": True, "facts": 0}, cost_cents=0
            )

        if self._forced_topics:
            ctx.auto_topics = list(self._forced_topics)
            topics = list(self._forced_topics)
        else:
            topics = self._derive_topics(ctx)

        # #72 F-1 (no-category mode): a missing topic signal (no category/theme,
        # generic-only prompt) used to fall straight through to the sources'
        # broad/generic feeds. When a pool is wired, sample a diverse concrete
        # topic set from it first (free, no LLM call); an empty/missing pool
        # returns None and we keep today's broad-feed fallback.
        if topics is None and self._topic_pool is not None:
            # #153: scale the no-category topic count with the order size —
            # a 30-question order needs ≥15 topics, not the fixed 5-topic
            # default, or a handful of topics end up carrying the whole pack.
            # DEFAULT_TOPIC_COUNT stays the floor for small orders; sample()
            # itself caps at the pool size.
            topic_count = max(DEFAULT_TOPIC_COUNT, math.ceil(ctx.target_count / 2))
            sampled = self._topic_pool.sample(topic_count)
            if sampled:
                ctx.auto_topics = sampled
                topics = sampled

        batch = await self._fact_sourcer.gather_facts(
            count=ctx.target_count * 2,
            topics=topics,
        )

        # #153 Phase 0.2: fail loud on any topic that sourced 0 facts instead
        # of silently contributing nothing.
        empty_topics, resampled_topics = await self._resample_empty_topics(
            batch, topics, ctx
        )

        # #153 Phase 0.3: drop listicle/low-credibility facts once their topic
        # already has enough trustworthy material (starvation-guarded).
        batch, low_credibility_dropped = batch.drop_low_credibility_starved()

        # RC-2 (#72 P3.2): give the flat-defaulted facts a real, free surprise
        # score and actually rank by it — top_by_surprise() previously had zero
        # call sites, so the generation prompt's "prefer surprising facts" never
        # bit. Ordering only (n = all facts): the 2× dedup headroom downstream is
        # preserved, the facts are just surprise-first so generation anchors on
        # the interesting ones. #153 Phase 0.3: credibility now leads that
        # ranking (see `FactBatch.top_by_surprise`).
        batch.score_surprise_heuristic()
        ctx.facts = batch.top_by_surprise(len(batch.facts))

        # Tavily spend is no longer estimated here (#95): every actual search
        # call reports its credits to app.cost_tracking, and the worker
        # persists the measured total. The old flat 1¢/order estimate missed
        # the per-question verification searches entirely.
        return StageResult(
            info={
                "facts": len(ctx.facts),
                "sources_used": list(batch.sources_used),
                # #72 F-1: surfaces which topics the pool picked (None on the
                # heuristic path) so a no-category run is auditable end-to-end.
                "auto_topics": ctx.auto_topics,
                # #153 Phase 0.2: always present so downstream analysis can see
                # the per-topic fact distribution (empty for the broad-feed
                # no-topics path, or when a test double doesn't populate it).
                "facts_per_topic": dict(batch.facts_per_topic),
                "empty_topics": empty_topics,
                "resampled_topics": resampled_topics,
                # #153 Phase 0.3
                "low_credibility_dropped": low_credibility_dropped,
            },
            cost_cents=0,
        )

    async def _resample_empty_topics(
        self, batch: FactBatch, topics: list[str] | None, ctx: OrderContext
    ) -> tuple[list[str], int]:
        """#153 Phase 0.2: give a topic that sourced 0 facts one bounded shot
        at a replacement before giving up on it loudly.

        Reads `batch.facts_per_topic` (populated by `FactSourcer.gather_facts`
        when `topics` is not None) rather than re-deriving counts from
        `batch.facts` — a test double that returns a fixed batch without
        setting it leaves the dict empty, so no topic is misreported as
        "empty" from stale/mismatched fact tagging.

        For each topic that yielded 0 facts: with no `TopicPool` wired
        (worker path today), or once the shared replacement budget
        (`len(topics)` total attempts across the whole run) is exhausted, the
        topic is logged and reported in `empty_topics` rather than silently
        contributing nothing. Otherwise a fresh, not-yet-tried topic is drawn
        from the pool and sourced; a non-empty replacement resolves the
        original topic (counted in `resampled_topics`), a still-empty one
        consumes another unit of budget and tries again.
        """
        if not topics:
            return [], 0

        facts_per_topic = dict(batch.facts_per_topic)
        empty = [t for t, n in facts_per_topic.items() if n == 0]
        if not empty:
            batch.facts_per_topic = facts_per_topic
            return [], 0

        used = {t.lower() for t in topics}
        budget = len(topics)
        attempts = 0
        per_topic_count = max((ctx.target_count * 2) // max(len(topics), 1), 5)

        empty_topics: list[str] = []
        resampled_topics = 0

        for topic in empty:
            if self._topic_pool is None:
                logger.warning(
                    "Sourcing topic %r yielded 0 facts; no TopicPool wired, "
                    "cannot resample.",
                    topic,
                )
                empty_topics.append(topic)
                continue

            resolved = False
            while attempts < budget:
                replacement_sample = self._topic_pool.sample(1, exclude=used)
                if not replacement_sample:
                    break  # pool has no unused topic left to try
                replacement = replacement_sample[0]
                used.add(replacement.lower())
                attempts += 1

                replacement_batch = await self._fact_sourcer.gather_facts(
                    count=per_topic_count, topics=[replacement]
                )
                replacement_count = len(replacement_batch.facts)
                facts_per_topic[replacement] = replacement_count
                if replacement_count > 0:
                    logger.warning(
                        "Sourcing topic %r yielded 0 facts; resampled "
                        "replacement topic %r (%d facts).",
                        topic,
                        replacement,
                        replacement_count,
                    )
                    batch.facts.extend(replacement_batch.facts)
                    resampled_topics += 1
                    resolved = True
                    break

            if not resolved:
                logger.warning(
                    "Sourcing topic %r yielded 0 facts; resample budget "
                    "exhausted (%d/%d attempts), leaving it empty.",
                    topic,
                    attempts,
                    budget,
                )
                empty_topics.append(topic)

        batch.facts_per_topic = facts_per_topic
        return empty_topics, resampled_topics

    @staticmethod
    def _derive_topics(ctx: OrderContext) -> list[str] | None:
        """Build the source topic filter from order metadata + prompt tokens.

        #42 task 42.28 (lever b): `category`/`theme` are blank on most orders,
        which left sourcing topic-agnostic — Wikipedia served generic DYK /
        featured facts and the questions drifted off-prompt. We now also mine
        a few salient tokens straight from `ctx.prompt` (no LLM) and append
        them, so the sources actually search for what the order asked about.
        Category/theme come first (they're the curated signal); prompt tokens
        fill in when they're absent. Returns None only when nothing usable is
        found, preserving the "no topics → broad feeds" fallback downstream.
        """
        topics: list[str] = []
        # De-dupe case-insensitively (prompt tokens are already lowercase) so a
        # category="History" plus a prompt "…history…" don't both survive and
        # make Wikipedia search the same concept twice (re-introducing the very
        # near-duplicate facts the fact partition removes).
        seen: set[str] = set()
        for meta in (ctx.category, ctx.theme):
            if meta and meta.lower() not in seen:
                topics.append(meta)
                seen.add(meta.lower())
        for token in SourcingStage._prompt_tokens(ctx.prompt):
            if token not in seen:
                topics.append(token)
                seen.add(token)
        return topics or None

    @staticmethod
    def _prompt_tokens(prompt: str | None) -> list[str]:
        """Mine up to `MAX_PROMPT_TOPIC_TOKENS` topic tokens from free text.

        Heuristic, no LLM: lowercase, split on `[a-z0-9]+`, drop ≤2-char tokens
        and a small stopword set, de-dupe preserving order, cap the count.
        """
        if not prompt:
            return []
        tokens: list[str] = []
        for match in re.findall(r"[a-z0-9]+", prompt.lower()):
            if len(match) <= 2 or match in _PROMPT_STOPWORDS:
                continue
            if match not in tokens:
                tokens.append(match)
            if len(tokens) >= MAX_PROMPT_TOPIC_TOKENS:
                break
        return tokens
