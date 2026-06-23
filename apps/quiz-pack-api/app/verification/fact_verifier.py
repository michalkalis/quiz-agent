"""Automated fact verification using Tavily search + Gemini Flash.

Two-stage pipeline:
1. Tavily search — find evidence for/against the claimed answer (~$0.005/query)
2. Gemini 2.5 Flash — analyze evidence if Tavily inconclusive (~$0.001/call)
"""

import json
import os
import re
from dataclasses import dataclass, field
from typing import Optional

from quiz_shared.llm import factory as llm_factory

from ..sourcing.web_search_source import WebSearchSource


@dataclass
class VerificationResult:
    """Result of fact-checking a question-answer pair."""

    verdict: str  # "verified" | "likely_correct" | "uncertain" | "likely_wrong" | "wrong"
    confidence: float  # 0.0 - 1.0
    sources: list[dict] = field(default_factory=list)  # [{url, excerpt, agrees}]
    alternative_answers: list[str] = field(default_factory=list)
    notes: str = ""
    held_for_review: bool = False


_SCALE = {
    "thousand": 1_000,
    "million": 1_000_000,
    "billion": 1_000_000_000,
    "trillion": 1_000_000_000_000,
}
_NUM_RE = re.compile(r"(\d[\d,]*\.?\d*)\s*(thousand|million|billion|trillion)?", re.IGNORECASE)


def _numbers_in(text: str) -> list[float]:
    """All numeric magnitudes in ``text``, honouring comma grouping + scale words.

    ``"4,000,000"`` → ``4e6``; ``"4 million"`` → ``4e6``; ``"3.5 billion"`` →
    ``3.5e9``. Powers the RC-9 numeric-agreement check so an estimation answer
    (``"about 4 million"``) can match a source that writes the figure
    differently (``"4,000,000"``).
    """
    out: list[float] = []
    for digits, scale in _NUM_RE.findall(text):
        try:
            value = float(digits.replace(",", ""))
        except ValueError:
            continue
        if scale:
            value *= _SCALE[scale.lower()]
        out.append(value)
    return out


def _answer_supported(claimed_answer: str, content_lower: str) -> bool:
    """Whether ``content_lower`` supports ``claimed_answer`` (RC-9).

    Crisp/recall answers keep the strict verbatim-substring test, so factual
    claims stay tightly gated. Numeric *estimation* answers (``"about 4
    million"``, ``"~30%"``) additionally match when the source states a value
    within 10% — so a non-substring estimate is no longer scored as
    disagreement and dropped. Verification used to select FOR boring,
    crisp-recall answers precisely because estimates never substring-matched.
    """
    answer_lower = claimed_answer.lower()
    if answer_lower in content_lower:
        return True
    answer_nums = _numbers_in(answer_lower)
    if not answer_nums:
        return False  # non-numeric recall answer → strict substring only
    target = answer_nums[0]
    if target == 0:
        return False
    return any(abs(n - target) <= 0.10 * abs(target) for n in _numbers_in(content_lower))


class FactVerifier:
    """Verifies question-answer pairs using web search and LLM analysis."""

    def __init__(
        self,
        tavily_api_key: Optional[str] = None,
        gemini_api_key: Optional[str] = None,
    ):
        self.search = WebSearchSource(api_key=tavily_api_key)
        self.gemini_api_key = gemini_api_key or os.getenv("GOOGLE_API_KEY")
        self._client = None

    def _available(self) -> bool:
        """Whether the LLM judge is reachable.

        Issue #53: the judge now runs through the OpenAI-compatible factory
        client. Under the OpenRouter gateway one key serves Gemini; in direct
        mode an explicit/ambient ``GOOGLE_API_KEY`` still marks it configured.
        """
        return bool(self.gemini_api_key) or llm_factory.gateway() == llm_factory.OPENROUTER

    async def _complete(self, prompt: str) -> Optional[str]:
        """Single LLM boundary: raw model text, or ``None`` on any failure."""
        if self._client is None:
            self._client = llm_factory.openai_client(async_=True)
        try:
            response = await self._client.chat.completions.create(
                model=llm_factory.resolve_model("gemini-2.5-flash"),
                messages=[{"role": "user", "content": prompt}],
            )
            return response.choices[0].message.content
        except Exception:
            return None

    async def verify(
        self, question: str, claimed_answer: str, topic: str = ""
    ) -> VerificationResult:
        """Verify a question-answer pair.

        Stage 1: Search for evidence via Tavily
        Stage 2: If inconclusive, analyze with Gemini Flash
        """
        # Stage 1: Tavily search
        search_results = await self.search.verify_claim(
            question=question,
            claimed_answer=claimed_answer,
            max_results=5,
        )

        if "error" in search_results and not search_results.get("results"):
            # RC-9: search unavailable ≠ wrong answer. Hold for review instead
            # of dropping at confidence 0 (a conf-0 drop silently sheds
            # possibly-good questions whenever the search tool is down).
            return VerificationResult(
                verdict="unverified",
                confidence=0.0,
                held_for_review=True,
                notes=f"Search unavailable ({search_results.get('error')}); held for review",
            )

        sources = []
        for result in search_results.get("results", []):
            content = (result.get("content") or "").lower()
            agrees = _answer_supported(claimed_answer, content)
            sources.append(
                {
                    "url": result.get("url", ""),
                    "excerpt": (result.get("content") or "")[:300],
                    "agrees_with_answer": agrees,
                    "relevance_score": result.get("score", 0),
                }
            )

        agreeing = sum(1 for s in sources if s["agrees_with_answer"])
        total = len(sources)

        # Quick verdict if evidence is clear
        if total >= 3 and agreeing >= 3:
            return VerificationResult(
                verdict="verified",
                confidence=min(0.95, 0.6 + (agreeing / total) * 0.35),
                sources=sources,
                notes=f"{agreeing}/{total} sources confirm the answer",
            )

        if total >= 3 and agreeing == 0:
            # No sources agree — likely wrong, but check with Gemini
            return await self._verify_with_gemini(
                question, claimed_answer, sources, search_results.get("answer")
            )

        # Inconclusive — use Gemini for deeper analysis
        if total > 0:
            return await self._verify_with_gemini(
                question, claimed_answer, sources, search_results.get("answer")
            )

        return VerificationResult(
            verdict="uncertain",
            confidence=0.2,
            sources=sources,
            notes="Insufficient search results",
        )

    async def _verify_with_gemini(
        self,
        question: str,
        claimed_answer: str,
        sources: list[dict],
        tavily_answer: Optional[str],
    ) -> VerificationResult:
        """Stage 2: Use Gemini Flash to analyze search evidence."""
        if not self._available():
            # Fallback: use heuristics only
            agreeing = sum(1 for s in sources if s["agrees_with_answer"])
            total = len(sources)
            if agreeing > total / 2:
                return VerificationResult(
                    verdict="likely_correct",
                    confidence=0.5 + (agreeing / max(total, 1)) * 0.2,
                    sources=sources,
                    notes="Gemini unavailable; heuristic verdict based on source agreement",
                )
            # RC-9: judge unavailable + no clear source agreement → we simply
            # could not verify. Hold for review rather than drop at low
            # confidence; dropping here selects FOR crisp recall answers that
            # happen to substring-match and against estimation/reasoning ones.
            return VerificationResult(
                verdict="unverified",
                confidence=0.3,
                sources=sources,
                held_for_review=True,
                notes="Judge unavailable; insufficient source agreement — held for review",
            )

        # Build evidence summary for Gemini
        evidence_lines = []
        for i, src in enumerate(sources, 1):
            agreement = "AGREES" if src["agrees_with_answer"] else "DOES NOT MENTION answer"
            evidence_lines.append(
                f"Source {i} ({src['url']}): {agreement}\n  Excerpt: {src['excerpt'][:200]}"
            )

        if tavily_answer:
            evidence_lines.append(f"\nTavily synthesized answer: {tavily_answer}")

        evidence_text = "\n".join(evidence_lines)

        prompt = f"""You are a fact-checker for a trivia quiz app. Verify this question-answer pair.

QUESTION: {question}
CLAIMED ANSWER: {claimed_answer}

SEARCH EVIDENCE:
{evidence_text}

Respond in JSON only:
{{
  "verdict": "verified" | "likely_correct" | "uncertain" | "likely_wrong" | "wrong",
  "confidence": 0.0-1.0,
  "reasoning": "Brief explanation",
  "correct_answer": "The actual correct answer if different, or null",
  "alternative_answers": ["other valid answers if any"]
}}

Rules:
- "verified": Multiple reliable sources confirm the answer
- "likely_correct": Evidence leans toward correct but not definitive
- "uncertain": Not enough evidence either way
- "likely_wrong": Evidence suggests a different answer
- "wrong": Sources clearly contradict the claimed answer
- Be conservative — "uncertain" is better than a wrong verdict"""

        try:
            text = await self._complete(prompt)
            if text is None:
                raise RuntimeError("Gemini call failed")
            text = text.strip()

            # Parse JSON from response
            if text.startswith("```"):
                text = text.split("\n", 1)[1].rsplit("```", 1)[0].strip()

            start = text.find("{")
            end = text.rfind("}") + 1
            if start == -1 or end <= start:
                raise ValueError("No JSON in Gemini response")

            data = json.loads(text[start:end])

            alternatives = data.get("alternative_answers", [])
            if data.get("correct_answer") and data["correct_answer"] != claimed_answer:
                alternatives.insert(0, data["correct_answer"])

            return VerificationResult(
                verdict=data.get("verdict", "uncertain"),
                confidence=float(data.get("confidence", 0.5)),
                sources=sources,
                alternative_answers=alternatives,
                notes=data.get("reasoning", ""),
            )

        except Exception as e:
            # Gemini failed — fall back to heuristic
            agreeing = sum(1 for s in sources if s["agrees_with_answer"])
            total = len(sources)
            return VerificationResult(
                verdict="uncertain",
                confidence=0.3,
                sources=sources,
                notes=f"Gemini analysis failed ({e}); heuristic fallback",
            )

    async def verify_batch(
        self, questions: list[dict]
    ) -> list[dict]:
        """Verify a batch of question-answer pairs.

        Args:
            questions: List of {"question": str, "correct_answer": str, "id": str, "topic": str}

        Returns:
            List of {"id": str, "verification": VerificationResult}
        """
        results = []
        for q in questions:
            result = await self.verify(
                question=q["question"],
                claimed_answer=str(q["correct_answer"]),
                topic=q.get("topic", ""),
            )
            results.append(
                {
                    "id": q.get("id", "unknown"),
                    "question": q["question"],
                    "claimed_answer": str(q["correct_answer"]),
                    "verification": result,
                }
            )
        return results
