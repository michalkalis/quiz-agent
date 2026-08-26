"""Web-grounded LLM fact-check (#166 increment 2, replaces Tavily+arbiter).

The previous verifier (Tavily snippet agreement + a DeepSeek evidence
arbiter) was blind on fresh facts: D21b measured recall 0/6 on the planted
2026-news errors, while the agentic Claude fact-check pattern (adversarial
prompt + web search, ``docs/testing/runs/d21b-round-2026-08-18/
factcheck_agent_2026-08-21.json``) caught 6/6. This module implements that
validated pattern in-pipeline: one LLM call per question with the provider's
native server-side web-search tool, returning an editorial verdict
``ok | fact_error | logic_flaw | stale``.

Provider swap (#166 provider research, founder-approved 2026-08-26): the
default backend is now OpenAI ``gpt-5-mini`` via the Responses API
``web_search`` tool — on the founder reference set it caught 7/7 errors at
~4 ¢/q vs 5/7 at ~18 ¢/q for the previous Sonnet 5 + Anthropic web_search
path (40-question validation, results in ``docs/testing/runs/
d21b-round-2026-08-18/factcheck-eval-166/`` and issue-166 § Follow-up
smery; the eval harness lands with PR #35). The
Anthropic path is kept verbatim: any ``claude*`` model id routes to it, so
``LLM_ROLE_FACTCHECK=claude-sonnet-5`` is the rollback lever.

Drop policy (founder-approved 2026-08-24): ``fact_error``/``logic_flaw``/
``stale`` are dropped; ``ok`` is kept. Mapped onto the existing numeric
contract so ``VerificationStage`` stays unchanged: problem verdicts carry
confidence 0.0 (below the 0.5 gate → dropped), ``ok`` carries ≥0.5.

Failure policy — fail closed (#158, #147 precedent): a missing key, an API
error, a refusal, or an unparseable reply is never evidence for OR against
the answer, so the question is ``held_for_review`` → the stage withholds it
and the top-up loop regenerates the shortfall. A systemic outage breaches
TopUp's 80% floor and fails the order loud instead of shipping unverified
content.
"""

import asyncio
import json
import os
from dataclasses import dataclass, field
from typing import Optional

from quiz_shared.llm import factory as llm_factory

# #150 — bound on concurrent per-question fact-check calls (same knob
# convention as SCORER_MAX_CONCURRENT); default matches the answerability
# stage's 8, now sized for Anthropic rate limits rather than Tavily.
MAX_CONCURRENT_VERIFICATIONS = int(os.getenv("VERIFIER_MAX_CONCURRENT", "8"))

# Server-side web-search cap per question (Anthropic path only — the OpenAI
# Responses web_search tool exposes no per-request cap; measured usage on the
# 40q validation averaged ~4 searches/q). The D21b agent rarely needed more
# than a handful of searches per verdict; 5 bounds worst-case cost (~5¢/q at
# $10 per 1k searches) without starving the adversarial pass.
_MAX_WEB_SEARCHES = 5

# Output budget for the OpenAI Responses path (reasoning + reply). 4096
# matched the Anthropic path's max_tokens and was never hit across the 60
# eval calls of the 2026-08-26 provider validation.
_MAX_OUTPUT_TOKENS_OPENAI = 4096

# pause_turn resumes: the server-side tool loop can pause a long turn; each
# resume re-sends the paused assistant turn. Bounded so a wedged turn cannot
# loop forever (#139: no unbounded hangs).
_MAX_PAUSE_RESUMES = 3

_PROBLEM_VERDICTS = frozenset({"fact_error", "logic_flaw", "stale"})
_CONFIDENCE_TO_SCORE = {"high": 0.9, "medium": 0.7, "low": 0.5}


@dataclass
class VerificationResult:
    """Result of fact-checking a question-answer pair."""

    verdict: str  # "ok" | "fact_error" | "logic_flaw" | "stale" | "unverified"
    confidence: float  # 0.0 - 1.0 (VerificationStage drops below 0.5)
    sources: list[dict] = field(default_factory=list)  # [{url, excerpt, agrees}]
    alternative_answers: list[str] = field(default_factory=list)
    notes: str = ""
    held_for_review: bool = False
    # Cost of this check in cents (tokens + web searches). The direct
    # Anthropic path is invisible to both order-level cost signals (Tavily
    # credits, OpenRouter delta), so VerificationStage sums this into
    # StageResult.cost_cents.
    cost_cents: float = 0.0


_PROMPT_TEMPLATE = """You are an adversarial fact-checker for a trivia quiz. Your job is to find problems with a question-answer pair, not to confirm it. Assume the question may have been written months ago: superlative or "only/most recent/current" claims can have been overtaken by newer events, so check for developments up to today.

QUESTION: {question}
CLAIMED ANSWER: {claimed_answer}
TOPIC: {topic}

Use web search to actively try to disprove the pair: verify the core fact, and search for newer events that could have invalidated it. Prefer primary or authoritative sources: Wikipedia (and the sources Wikipedia itself cites) and domain authorities (e.g. IMDb for film, official chart/records bodies) outrank news sites, and news sites outrank aggregators and listicles — never trust a low-quality aggregator over them. If authoritative sources genuinely contradict each other on a fact the pair depends on, the pair is not safely usable — verdict "logic_flaw".

Give exactly one verdict:
- "fact_error" — the claimed answer is factually wrong, or the question asserts something false
- "logic_flaw" — the question is ambiguous, self-contradictory, or has multiple defensible answers
- "stale" — the pair was true once but has been superseded by newer events
- "ok" — you found no problem

End your reply with ONLY a single JSON object on its own line:
{{"verdict": "ok|fact_error|logic_flaw|stale", "confidence": "high|medium|low", "note": "one-sentence justification with a source URL for any problem found", "correct_answer": "the actual answer if the claimed one is wrong, else null"}}"""


class FactVerifier:
    """Fact-checks question-answer pairs with an LLM + native web search.

    Contract #53: SDK clients come from ``quiz_shared.llm.factory``
    (``openai_client(direct=True)`` / ``anthropic_client()``) — never
    constructed here. Neither provider's server-side web-search tool is
    served by an OpenAI-compatible gateway, so this role is a
    direct-provider carve-out analogous to audio/image (``direct=True``).

    The model id picks the backend: ``claude*`` → Anthropic messages +
    ``web_search_20260209``; anything else → OpenAI Responses +
    ``web_search``.
    """

    def __init__(self, model: Optional[str] = None):
        self._model = model or llm_factory.FACTCHECK
        self._client = None

    def _is_anthropic(self) -> bool:
        return self._model.startswith("claude")

    def _available(self) -> bool:
        """Whether the fact-check backend is reachable.

        An injected client (tests) is always available; otherwise the
        active provider's key must be present. No key → every question is
        held → withheld by the stage (fail-closed, never silently skipped).
        """
        if self._client is not None:
            return True
        key = "ANTHROPIC_API_KEY" if self._is_anthropic() else "OPENAI_API_KEY"
        return bool(os.getenv(key))

    async def _call(self, prompt: str) -> tuple[Optional[str], float]:
        if self._is_anthropic():
            return await self._call_anthropic(prompt)
        return await self._call_openai(prompt)

    async def _call_openai(self, prompt: str) -> tuple[Optional[str], float]:
        """One Responses-API fact-check turn: ``(reply text, cost cents)``.

        Mirrors ``_call_anthropic``'s failure contract: a ``None`` text is
        "could not check" (API error after SDK retries, a non-completed
        response — e.g. truncated at ``max_output_tokens`` — or an empty
        reply), never a verdict. Cost = tokens at list price + $10/1k
        web-search calls, billed even when the turn ultimately fails.
        """
        cost_cents = 0.0
        try:
            if self._client is None:
                self._client = llm_factory.openai_client(
                    async_=True,
                    direct=True,
                    timeout=llm_factory.GENERATION_TIMEOUT,
                )

            response = await self._client.responses.create(
                model=self._model,
                tools=[{"type": "web_search"}],
                input=prompt,
                max_output_tokens=_MAX_OUTPUT_TOKENS_OPENAI,
            )
            cost_cents = self._record_usage_openai(response)

            if getattr(response, "status", None) != "completed":
                return None, cost_cents
            text = "".join(
                getattr(content, "text", "")
                for item in response.output
                if getattr(item, "type", None) == "message"
                for content in getattr(item, "content", [])
            )
            return text or None, cost_cents
        except Exception:
            return None, cost_cents

    def _record_usage_openai(self, response) -> float:
        """Report token usage (#153 recorder) and return the call's cost in
        cents (tokens at list price + $10/1k web-search tool calls)."""
        try:
            from app import llm_usage

            usage = response.usage
            handler = llm_factory.get_usage_handler()
            record = getattr(handler, "record_direct", None)
            if record is not None:
                record(self._model, usage.input_tokens, usage.output_tokens)
            searches = sum(
                1
                for item in response.output
                if getattr(item, "type", None) == "web_search_call"
            )
            return (
                llm_usage.cost_cents_for(
                    self._model, usage.input_tokens, usage.output_tokens
                )
                + searches * 1.0
            )
        except Exception:  # accounting must never fail a verification
            return 0.0

    async def _call_anthropic(self, prompt: str) -> tuple[Optional[str], float]:
        """One fact-check turn: ``(final reply text, cost in cents)``.

        A ``None`` text covers every way the backend goes silent — API errors
        after SDK retries, a safety refusal, or a turn still paused after
        ``_MAX_PAUSE_RESUMES`` — all of which read as "could not check", not
        as a verdict. Cost is accumulated across pause_turn resumes; billed
        tokens/searches count even when the turn ultimately fails.
        """
        cost_cents = 0.0
        try:
            if self._client is None:
                self._client = llm_factory.anthropic_client()

            messages = [{"role": "user", "content": prompt}]
            tools = [
                {
                    "type": "web_search_20260209",
                    "name": "web_search",
                    "max_uses": _MAX_WEB_SEARCHES,
                }
            ]
            response = None
            for _ in range(1 + _MAX_PAUSE_RESUMES):
                # Always the direct Anthropic id — this path never routes
                # through a gateway, so no resolve_model remap applies.
                response = await self._client.messages.create(
                    model=self._model,
                    max_tokens=4096,
                    tools=tools,
                    messages=messages,
                )
                cost_cents += self._record_usage(response)
                if response.stop_reason != "pause_turn":
                    break
                # Server-side tool loop paused mid-turn — re-send the paused
                # assistant turn so the server resumes where it left off.
                messages = [
                    {"role": "user", "content": prompt},
                    {"role": "assistant", "content": response.content},
                ]

            if response is None or response.stop_reason in ("refusal", "pause_turn"):
                return None, cost_cents

            text = "".join(
                block.text
                for block in response.content
                if getattr(block, "type", None) == "text"
            )
            return text or None, cost_cents
        except Exception:
            return None, cost_cents

    def _record_usage(self, response) -> float:
        """Report token usage (#153 recorder) and return this call's cost in
        cents (tokens at list price + $10/1k web searches).

        The recorder's normal interception point is the LangChain factory
        path; this call goes through the native Anthropic SDK, so report
        directly — otherwise the fact-check stage would be an invisible cost
        gap in every per-order summary.
        """
        try:
            from app import llm_usage

            usage = response.usage
            handler = llm_factory.get_usage_handler()
            record = getattr(handler, "record_direct", None)
            if record is not None:
                record(self._model, usage.input_tokens, usage.output_tokens)
            searches = getattr(
                getattr(usage, "server_tool_use", None), "web_search_requests", 0
            )
            return (
                llm_usage.cost_cents_for(
                    self._model, usage.input_tokens, usage.output_tokens
                )
                + (searches or 0) * 1.0
            )
        except Exception:  # accounting must never fail a verification
            return 0.0

    async def verify(
        self, question: str, claimed_answer: str, topic: str = ""
    ) -> VerificationResult:
        """Fact-check one question-answer pair (see module docstring)."""
        if not self._available():
            key = "ANTHROPIC_API_KEY" if self._is_anthropic() else "OPENAI_API_KEY"
            return self._held(f"{key} not configured")

        prompt = _PROMPT_TEMPLATE.format(
            question=question, claimed_answer=claimed_answer, topic=topic or "n/a"
        )
        text, cost_cents = await self._call(prompt)
        if text is None:
            return self._held(
                "fact-check call failed (API error or refusal)", cost_cents
            )

        data = _parse_verdict_json(text)
        if data is None:
            return self._held(
                "fact-check reply had no parseable verdict JSON", cost_cents
            )

        verdict = str(data.get("verdict", "")).strip().lower()
        note = str(data.get("note") or "")
        correct = data.get("correct_answer")
        alternatives = [str(correct)] if correct and correct != claimed_answer else []

        if verdict in _PROBLEM_VERDICTS:
            return VerificationResult(
                verdict=verdict,
                confidence=0.0,  # below the stage gate → dropped
                alternative_answers=alternatives,
                notes=note,
                cost_cents=cost_cents,
            )
        if verdict == "ok":
            score = _CONFIDENCE_TO_SCORE.get(
                str(data.get("confidence", "")).strip().lower(), 0.5
            )
            return VerificationResult(
                verdict="ok", confidence=score, notes=note, cost_cents=cost_cents
            )

        # Unknown verdict string — a checker bug, not evidence either way.
        return self._held(
            f"fact-check returned unknown verdict {verdict!r}", cost_cents
        )

    def _held(self, reason: str, cost_cents: float = 0.0) -> VerificationResult:
        """Fail-closed verdict: could not check → withhold, never drop/keep."""
        return VerificationResult(
            verdict="unverified",
            confidence=0.0,
            held_for_review=True,
            notes=f"{reason}; held (fail-closed, #158)",
            cost_cents=cost_cents,
        )

    async def verify_batch(self, questions: list[dict]) -> list[dict]:
        """Verify a batch concurrently, bounded by `MAX_CONCURRENT_VERIFICATIONS`.

        `gather` preserves input order, so the returned list is positionally
        identical to the sequential version — callers index it by ``id``.

        Args:
            questions: List of {"question": str, "correct_answer": str, "id": str, "topic": str}

        Returns:
            List of {"id": str, "verification": VerificationResult}
        """
        semaphore = asyncio.Semaphore(MAX_CONCURRENT_VERIFICATIONS)

        async def _verify_one(q: dict) -> dict:
            async with semaphore:
                result = await self.verify(
                    question=q["question"],
                    claimed_answer=str(q["correct_answer"]),
                    topic=q.get("topic", ""),
                )
            return {
                "id": q.get("id", "unknown"),
                "question": q["question"],
                "claimed_answer": str(q["correct_answer"]),
                "verification": result,
            }

        return list(await asyncio.gather(*(_verify_one(q) for q in questions)))


def _parse_verdict_json(text: str) -> Optional[dict]:
    """Last ``{"verdict": ...}`` object in ``text``, or ``None``.

    The prompt asks for a trailing JSON object, but the reply may also carry
    prose, search citations, or a code fence — scan from the last candidate
    opening brace and decode leniently.
    """
    idx = text.rfind('{"verdict"')
    if idx == -1:
        idx = text.rfind("{")
    if idx == -1:
        return None
    try:
        data, _ = json.JSONDecoder().raw_decode(text[idx:])
    except ValueError:
        return None
    return data if isinstance(data, dict) else None
