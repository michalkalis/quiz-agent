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

import re

from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink
from app.sourcing.fact_sourcer import FactSourcer
from app.sourcing.topic_planner import TopicPlanner

TAVILY_CENTS_PER_CALL = 1

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
        # no tokens → topics None → SourcingStage triggers the LLM TopicPlanner
        # instead of searching "surprising facts about general" (the listicle/
        # military-bias dead end). They are genuinely non-topical, so dropping
        # them never costs a real topic ("general relativity" still keeps
        # "relativity").
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
        topic_planner: TopicPlanner | None = None,
    ) -> None:
        self._fact_sourcer = fact_sourcer
        # #72 F-1: dormant by default. Only the CLI/batch path injects a planner
        # (Scope A) — the worker/live path leaves it None so its behavior stays
        # byte-identical until the no-category mode is exposed to the app.
        self._topic_planner = topic_planner

    async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
        topics = self._derive_topics(ctx)

        # #72 F-1 (no-category mode): a missing topic signal (no category/theme,
        # generic-only prompt) used to fall straight through to the sources'
        # broad/generic feeds — the listicle/military-bias dead end. When a
        # planner is wired, ask it for a diverse concrete topic set first; on any
        # failure it returns None and we keep today's broad-feed fallback.
        if topics is None and self._topic_planner is not None:
            proposed = await self._topic_planner.propose()
            if proposed:
                ctx.llm_topics = proposed
                topics = proposed

        batch = await self._fact_sourcer.gather_facts(
            count=ctx.target_count * 2,
            topics=topics,
        )
        # RC-2 (#72 P3.2): give the flat-defaulted facts a real, free surprise
        # score and actually rank by it — top_by_surprise() previously had zero
        # call sites, so the generation prompt's "prefer surprising facts" never
        # bit. Ordering only (n = all facts): the 2× dedup headroom downstream is
        # preserved, the facts are just surprise-first so generation anchors on
        # the interesting ones.
        batch.score_surprise_heuristic()
        ctx.facts = batch.top_by_surprise(len(batch.facts))

        tavily_calls = 1 if "web_search" in batch.sources_used else 0
        cost_cents = tavily_calls * TAVILY_CENTS_PER_CALL

        return StageResult(
            info={
                "facts": len(ctx.facts),
                "sources_used": list(batch.sources_used),
                # #72 F-1: surfaces which topics the planner picked (None on the
                # heuristic path) so a no-category run is auditable end-to-end.
                "llm_topics": ctx.llm_topics,
            },
            cost_cents=cost_cents,
        )

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
