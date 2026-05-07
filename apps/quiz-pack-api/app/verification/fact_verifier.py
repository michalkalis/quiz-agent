"""Automated fact verification using Tavily search + Gemini Flash.

Two-stage pipeline:
1. Tavily search — find evidence for/against the claimed answer (~$0.005/query)
2. Gemini 2.5 Flash — analyze evidence if Tavily inconclusive (~$0.001/call)
"""

import json
import os
from dataclasses import dataclass, field
from typing import Optional

from ..sourcing.web_search_source import WebSearchSource


@dataclass
class VerificationResult:
    """Result of fact-checking a question-answer pair."""

    verdict: str  # "verified" | "likely_correct" | "uncertain" | "likely_wrong" | "wrong"
    confidence: float  # 0.0 - 1.0
    sources: list[dict] = field(default_factory=list)  # [{url, excerpt, agrees}]
    alternative_answers: list[str] = field(default_factory=list)
    notes: str = ""


class FactVerifier:
    """Verifies question-answer pairs using web search and LLM analysis."""

    def __init__(
        self,
        tavily_api_key: Optional[str] = None,
        gemini_api_key: Optional[str] = None,
    ):
        self.search = WebSearchSource(api_key=tavily_api_key)
        self.gemini_api_key = gemini_api_key or os.getenv("GOOGLE_API_KEY")
        self._gemini_model = None

    def _get_gemini(self):
        """Lazy-init Gemini client."""
        if self._gemini_model is None and self.gemini_api_key:
            import google.generativeai as genai

            genai.configure(api_key=self.gemini_api_key)
            self._gemini_model = genai.GenerativeModel("gemini-2.5-flash")
        return self._gemini_model

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
            return VerificationResult(
                verdict="uncertain",
                confidence=0.0,
                notes=f"Search failed: {search_results.get('error')}",
            )

        sources = []
        for result in search_results.get("results", []):
            content = (result.get("content") or "").lower()
            answer_lower = claimed_answer.lower()
            agrees = answer_lower in content
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
        gemini = self._get_gemini()
        if gemini is None:
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
            return VerificationResult(
                verdict="uncertain",
                confidence=0.3,
                sources=sources,
                notes="Gemini unavailable; insufficient evidence for confident verdict",
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
            response = await gemini.generate_content_async(prompt)
            text = response.text.strip()

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
