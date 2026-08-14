"""Feature flags for the #72 generation-quality overhaul.

2026-08: the quality-safeguard flags (``V3_ESCAPE_HATCH``, ``GEN_CRAFT_GUARDS``,
``VETO_ENFORCE``, ``CRAFT_GUARDS_ENFORCE``) now default ON — prod Fly secrets
already set them, so a local/CLI run with nothing set was silently missing the
safeguards (Bedrock field test 2026-08-01). An explicit falsy env value
("0"/"false"/"no"/"off") still disables any of them; see ``_default_on``.
``EXPIRY_CLASSIFICATION`` and ``MCQ_CRITIQUE_TELEMETRY`` stay dormant/off by
default (see ``_truthy``) — neither has been validated yet. Model overrides
(``GENERATION_MODEL``/``CRITIQUE_MODEL``) stay ``None`` by default.

Env-driven on purpose: the generation/scoring/verification layers configure
themselves via inline ``os.getenv()`` (see ``answer_normalizer``,
``multi_model_scorer``, ``fact_verifier``), not the Pydantic ``Settings`` in
``app.config`` (which is infra-only). These flags follow that convention so the
gen layer keeps zero dependency on the settings object.

Do **not** flip ``LLM_GATEWAY`` here — that is a repo-wide gateway switch
(direct ↔ openrouter) affecting verification and scoring too, set at deploy
time, not a #72 flag (see issue plan, Phase 0).
"""

from __future__ import annotations

import os

_TRUTHY = {"1", "true", "yes", "on"}
_FALSY = {"0", "false", "no", "off"}


def _truthy(value: str | None) -> bool:
    return (value or "").strip().lower() in _TRUTHY


def _default_on(value: str | None) -> bool:
    """Like `_truthy`, but the unset/blank default is True, not False.

    2026-08: prod Fly secrets already set these quality-safeguard flags, so a
    local/CLI run with nothing set was silently missing them (Bedrock field
    test 2026-08-01). An explicit falsy value ("0"/"false"/"no"/"off",
    case-insensitive) still disables the flag.
    """
    value = (value or "").strip().lower()
    if not value:
        return True
    return value not in _FALSY


def generation_model() -> str | None:
    """Lever A (Phase 1): override the creative-generation model.

    ``None`` (default) → the generator keeps its current hardcoded default
    (``gpt-4o``). Phase 1 wires this in and defaults it to ``claude-opus-4-8``
    via the OpenRouter remap; dormant until then.
    """
    return os.getenv("GENERATION_MODEL") or None


def critique_model() -> str | None:
    """Lever A (Phase 1): override the critique model.

    ``None`` (default) → the generator keeps its current default
    (``gpt-4o-mini``).
    """
    return os.getenv("CRITIQUE_MODEL") or None


def v3_escape_hatch() -> bool:
    """Lever B (Phase 2): allow a surprising angle from general knowledge so
    long as the factual claim still traces to a source.

    ``True`` by default (2026-08: prod parity — see ``_default_on``); set
    ``V3_ESCAPE_HATCH=0``/``false`` to fall back to the hard-bound
    ``v3_fact_first`` prompt only.
    """
    return _default_on(os.getenv("V3_ESCAPE_HATCH"))


def gen_craft_guards() -> bool:
    """#72 reviewer upgrade (Phase 3): inject the founder-calibrated craft
    guards into the live v3 generation prompt (no stem leak, one sharp hook,
    named wrong assumption, gettable answer, T/F balance + transform-to-MCQ,
    no unguessable open numeric, answer-context payoff).

    ``True`` by default (2026-08: prod parity — see ``_default_on``); set
    ``GEN_CRAFT_GUARDS=0``/``false`` for the byte-identical old prompt.
    """
    return _default_on(os.getenv("GEN_CRAFT_GUARDS"))


def veto_shadow() -> bool:
    """Lever C (Phase 4): run the Answerability/surprise veto in shadow mode —
    log what *would* drop, drop nothing.

    ``False`` (default) → the veto is not consulted at all.
    """
    return _truthy(os.getenv("VETO_SHADOW"))


def veto_enforce() -> bool:
    """#72 reviewer upgrade (Phase 2): promote the Answerability/surprise veto
    from shadow to enforcing — flagged questions are DROPPED.

    ``True`` by default (2026-08: prod parity — see ``_default_on``); turning
    this on implies consultation regardless of ``VETO_SHADOW``. Set
    ``VETO_ENFORCE=0``/``false`` to fall back to shadow-only (see
    ``veto_shadow``).
    """
    return _default_on(os.getenv("VETO_ENFORCE"))


def craft_guards_enforce() -> bool:
    """#72 reviewer upgrade (Phase 2): promote the deterministic craft guards
    (stem answer-leak, T/F key-balance) from shadow to dropping.

    ``True`` by default (2026-08: prod parity — see ``_default_on``); set
    ``CRAFT_GUARDS_ENFORCE=0``/``false`` to run guards in shadow only
    (computed and counted in the stage info, nothing dropped).
    """
    return _default_on(os.getenv("CRAFT_GUARDS_ENFORCE"))


def expiry_classification() -> bool:
    """Issue #76 F-3b: run the post-generation expiry classifier.

    ``False`` (default) → ``GenerationStage`` gets no classifier and behaves
    byte-identically to pre-#76 (``expires_at``/``freshness_tag`` left unset).
    When on, one batched cheap-model call per run classifies each question's
    temporal freshness and the stage stamps a TTL for `current`/`semi-stable`
    questions. Kept dormant so existing tests + the order-e2e gate stay green
    without mocking a new LLM call.
    """
    return _truthy(os.getenv("EXPIRY_CLASSIFICATION"))


def mcq_critique_telemetry() -> bool:
    """Lever D (Phase 4): run the self_critique judge over the MCQ sub-batch
    questions as **telemetry** — annotate each kept question with a
    ``critique_score``, drop nothing.

    ``False`` (default) → the per-pattern MCQ sub-batch path stays
    critique-free (the shipped architecture, no extra LLM call per MCQ
    question). This restores the RC-7 MCQ quality signal that the text
    best-of-N path already records, without re-introducing the ~57-question
    over-generation the sub-batch path was built to replace.
    """
    return _truthy(os.getenv("MCQ_CRITIQUE_TELEMETRY"))


# --- #135 gen-pipeline founder feedback round 2 (2026-08-03) -----------------
# Every quality-relevant knob below is env-switchable on purpose: the founder's
# condition on the call-count diet (D6) was that old and new values both stay
# reachable via config, so a future quality drop can be traced by flipping one
# env var, not by a git archaeology session. Old→new values are logged in
# docs/issues/issue-135-… § Setting changes.


def _int_env(name: str, default: int, minimum: int = 1) -> int:
    """Integer env override with a floor; falls back to ``default`` on junk."""
    raw = (os.getenv(name) or "").strip()
    if not raw:
        return default
    try:
        return max(minimum, int(raw))
    except ValueError:
        return default


def verify_model() -> str | None:
    """#135 D9: override the fact/logical-verification arbiter model.

    ``None`` (default) → the factory ``VERIFY`` role (deepseek-v4-pro since
    2026-08-03, the founder's cheaper-arbiter carve-out). Set ``VERIFY_MODEL``
    (e.g. ``gemini-3.1-pro-preview``) to switch back.
    """
    return os.getenv("VERIFY_MODEL") or None


def answerability_model() -> str | None:
    """#135 D10: override the round-trip answerability-check model.

    ``None`` (default) → the factory ``ANSWERABILITY`` role.
    """
    return os.getenv("ANSWERABILITY_MODEL") or None


def answerability_check() -> bool:
    """#135 D10 (T4): early round-trip answerability check after dedup.

    ``True`` by default — founder-approved as a real early gate ("placed as
    EARLY as possible … also catches unclear phrasing/format"). Set
    ``ANSWERABILITY_CHECK=0`` to remove the stage entirely.
    """
    return _default_on(os.getenv("ANSWERABILITY_CHECK"))


def overgen_multiplier() -> int:
    """#135 D6 (T5): best-of-N over-generation factor.

    Default **2** (was 3 until 2026-08-03 — call-count diet, founder
    confirmed). Set ``OVERGEN_MULTIPLIER=3`` to restore the old breadth.
    """
    return _int_env("OVERGEN_MULTIPLIER", default=2)


def duel_ring_neighbours() -> int:
    """#135 D6 (T5): pairwise-duel ring width (neighbours per candidate).

    Default **3** (was 5 until 2026-08-03 — call-count diet, founder
    confirmed). Set ``DUEL_RING_NEIGHBOURS=5`` to restore the old ring.
    """
    return _int_env("DUEL_RING_NEIGHBOURS", default=3)


def judge_quorum() -> int:
    """#159 (gen-review P4): minimum count of REAL judge verdicts a question
    needs before the ship gate may act on its score.

    Default **2** — one judge of three is not a panel, and #147 already
    established that an unjudged question is withheld. ``JUDGE_QUORUM=1`` is
    the rollback lever only (restores the pre-#159 single-judge gate); raising
    or lowering it otherwise is a threshold change gated by P6 (eval data +
    founder approval).
    """
    return _int_env("JUDGE_QUORUM", default=2)


def gate_v2() -> bool:
    """#135 D7 (T6): the redesigned scoring gate — 5 dimensions, a 3-family
    judge panel (GPT + Gemini + cheap Chinese frontier), ONE call per judge
    with reasoning-first structured output.

    ``False`` by default — the founder's condition is a calibration-set
    validation (old vs new vs founder ratings, ``scripts/validate_gate_v2.py``)
    BEFORE the default flips. Set ``GATE_V2=1`` to enable.
    """
    return _truthy(os.getenv("GATE_V2"))


def gate_v2_clustered() -> bool:
    """#135 T6 fallback (founder go 2026-08-04): split the gate-v2 panel call
    into 2 cluster calls per judge — fun (spark/surprise/tellability) and
    craft (framing/answerability) — the middle ground between one call per
    dimension (v1) and all dims in one call (v2).

    Only meaningful with ``GATE_V2`` on. ``False`` by default — same flip
    condition as ``GATE_V2`` (calibration-set validation + founder go).
    Set ``GATE_V2_CLUSTERED=1`` to enable.
    """
    return _truthy(os.getenv("GATE_V2_CLUSTERED"))


def judge_models() -> list[str] | None:
    """#135 T2: override the gate judge panel (comma-separated factory ids).

    ``None`` (default) → role defaults (``SCORE_OPENAI``/``SCORE_GOOGLE`` and,
    under ``GATE_V2``, ``SCORE_THIRD``). Example:
    ``JUDGE_MODELS=gpt-5.6-sol,gemini-3.1-pro-preview,glm-5.1``.
    """
    raw = (os.getenv("JUDGE_MODELS") or "").strip()
    if not raw:
        return None
    models = [m.strip() for m in raw.split(",") if m.strip()]
    return models or None
