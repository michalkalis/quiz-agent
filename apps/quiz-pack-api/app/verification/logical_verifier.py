"""Issue #46 task 46.B5 — consistency verification for lateral-thinking puzzles.

Pure lateral puzzles have no web source (`pipeline = "logical_puzzle"`, D4), so
`FactVerifier` either drops them for low confidence or accepts them on a
spurious tangential match. This verifier asks an LLM judge — no web — the only
question that matters for a puzzle: does the answer *uniquely follow* from the
setup as written?

It returns the same `VerificationResult` shape as `FactVerifier` so
`VerificationStage` can dispatch on `verification_mode` (46.B6) and treat both
verdicts identically downstream. The judge checks the four properties from D2:

- **uniqueness** — is this the one answer, or are there equally-valid others?
- **deducibility** — can a reasonable player reason to it from the setup?
- **alternative answers** — any other answers that must also be accepted
  (→ populate `alternative_answers`, mirroring `FactVerifier`).
- **self-contained setup** — does the setup carry every fact needed, with no
  outside knowledge required?

Fail-safe by construction: no API key, an unparseable response, or any error
returns an ``uncertain`` verdict at low confidence — never a false ``verified``.
"""

from __future__ import annotations

import json
import os
from typing import Optional

from quiz_shared.llm import factory as llm_factory

from .fact_verifier import VerificationResult

_PROMPT = """You are a logic judge for a voice trivia app. The question below is a
lateral-thinking puzzle with NO external/web source — it must be solvable purely
by reasoning from the setup. Judge whether the claimed answer holds up.

QUESTION (setup): {question}
CLAIMED ANSWER: {claimed_answer}

Assess four properties:
1. uniqueness — is this the single best answer, or are other answers equally valid?
2. deducibility — can a reasonable player reason to it from the setup alone?
3. alternative answers — list any OTHER answers that must also be accepted as correct.
4. self-contained — does the setup contain every fact needed (no outside knowledge)?

Respond in JSON only:
{{
  "verdict": "verified" | "likely_correct" | "uncertain" | "likely_wrong" | "wrong",
  "confidence": 0.0-1.0,
  "reasoning": "Brief explanation",
  "alternative_answers": ["other valid answers, if any"]
}}

Rules:
- "verified": the answer uniquely and deducibly follows from a self-contained setup.
- "likely_correct": it follows, but the setup leans on a small unstated assumption.
- "uncertain": you cannot tell whether it uniquely follows.
- "likely_wrong"/"wrong": another answer fits better, or the setup is not self-contained.
- Be conservative — "uncertain" is better than a wrong verdict."""


class LogicalConsistencyVerifier:
    """Verifies lateral-thinking puzzles by reasoning, with no web search.

    Mirrors `FactVerifier`'s lazy Gemini-Flash client so the dependency stays
    optional: with no API key the model never inits and `verify` returns an
    ``uncertain`` verdict (fail-safe — never a false ``verified``).
    """

    def __init__(self, gemini_api_key: Optional[str] = None):
        self.gemini_api_key = gemini_api_key or os.getenv("GOOGLE_API_KEY")
        self._client = None

    def _available(self) -> bool:
        """Whether the LLM judge is reachable (see FactVerifier._available)."""
        return bool(self.gemini_api_key) or llm_factory.gateway() == llm_factory.OPENROUTER

    async def _complete(self, prompt: str) -> Optional[str]:
        """Single LLM boundary: raw model text, or ``None`` on any failure."""
        if self._client is None:
            # Offline generation pipeline — needs longer than the voice-path default.
            self._client = llm_factory.openai_client(
                async_=True, timeout=llm_factory.GENERATION_TIMEOUT
            )
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
        """Judge whether the claimed answer uniquely follows from the setup.

        Returns an ``uncertain`` / low-confidence result whenever the model is
        unavailable or the response can't be parsed — never a false positive.
        """
        if not self._available():
            return VerificationResult(
                verdict="uncertain",
                confidence=0.0,
                notes="Gemini unavailable; cannot judge logical consistency",
            )

        prompt = _PROMPT.format(question=question, claimed_answer=claimed_answer)
        try:
            text = await self._complete(prompt)
            if text is None:
                raise RuntimeError("Gemini call failed")
            text = text.strip()

            if text.startswith("```"):
                text = text.split("\n", 1)[1].rsplit("```", 1)[0].strip()

            start = text.find("{")
            end = text.rfind("}") + 1
            if start == -1 or end <= start:
                raise ValueError("No JSON in Gemini response")

            data = json.loads(text[start:end])

            return VerificationResult(
                verdict=data.get("verdict", "uncertain"),
                confidence=float(data.get("confidence", 0.5)),
                alternative_answers=data.get("alternative_answers", []),
                notes=data.get("reasoning", ""),
            )

        except Exception as e:
            return VerificationResult(
                verdict="uncertain",
                confidence=0.2,
                notes=f"Logical consistency judge failed ({e})",
            )
