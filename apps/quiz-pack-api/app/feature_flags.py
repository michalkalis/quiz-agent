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
