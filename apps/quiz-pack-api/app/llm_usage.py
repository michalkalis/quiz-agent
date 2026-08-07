"""Per-stage, per-model LLM token/cost accounting (#153 Phase 0.5).

Today the only cost signal is order-level: Tavily search credits
(`app.cost_tracking`) and an OpenRouter account-usage delta that bundles every
LLM call in the run into one number. #153's model/judge/facts matrix needs a
per-arm $/question figure broken down by pipeline stage and model — this
module is the per-call counter that feeds it.

**Interception point:** `quiz_shared.llm.factory.chat_openai` (aliased
`chat_model`) is the one place every LangChain chat client in this repo is
constructed (repo rule: no LLM SDK clients outside the factory). The factory
exposes `set_usage_handler`/`get_usage_handler`; when a handler is
registered, `chat_openai` attaches it to the client's `callbacks` so every
call that client makes reports here.

**Attribution** rides `current_stage`, a contextvar set by
`PackGenerator.run`'s stage loop (and, inside `TopUpStage`, reset around each
inner sub-stage `.run` call so top-up rounds attribute to
generation/verify/scoring rather than to "topup"). It is NOT derived from
LangChain's own run-tree/metadata — the pipeline's stage boundaries don't map
onto LangChain's run hierarchy.

**Coverage gap (fail loud, not silently incomplete):** only LangChain-path
chat calls are counted. Several collaborators build a *native* OpenAI SDK
client via `factory.openai_client()` instead of `chat_openai()`, and those
calls are invisible here:
- `app/sourcing/opentriviadb_source.py`, `app/sourcing/topic_planner.py` —
  topic-sourcing chat completions.
- `packages/shared/quiz_shared/utils/embeddings.py` — embedding calls.
- `app/image_generation/hint_images.py`, `silhouette_questions.py` — image
  generation (billed per-image, not per-token, so out of scope anyway).
`summary()`'s `"coverage"` field restates this so a consumer of the JSON
never mistakes a low total for the whole pipeline's spend.

**Concurrency:** `UsageRecorder` is a plain dict — fine for one CLI process
or one worker's single event loop. The ARQ worker runs up to
`WorkerSettings.max_jobs=2` orders concurrently in one process; two orders
in flight at once will attribute into whichever recorder is currently
registered via `set_usage_handler`, same shared-account caveat
`app.cost_tracking`'s OpenRouter delta already documents. Acceptable for
#153's offline experiment/CLI runs (the primary consumer); revisit with a
contextvar-scoped recorder if per-order precision is needed in prod.
"""

from __future__ import annotations

import contextvars
import logging
from typing import Any

from langchain_core.callbacks import BaseCallbackHandler
from langchain_core.outputs import LLMResult

logger = logging.getLogger(__name__)

current_stage: contextvars.ContextVar[str] = contextvars.ContextVar(
    "llm_usage_current_stage", default="unattributed"
)

COVERAGE_NOTE = (
    "Counts only LangChain-path chat calls (quiz_shared.llm.factory."
    "chat_openai/chat_model — the sole LLM-client interception point). "
    "Known gaps, never wrapped: app/sourcing/opentriviadb_source.py + "
    "app/sourcing/topic_planner.py (topic-sourcing chat calls via native "
    "openai_client()), packages/shared/quiz_shared/utils/embeddings.py "
    "(embedding calls), app/image_generation/hint_images.py + "
    "silhouette_questions.py (image generation, priced per-image anyway)."
)

# USD per 1,000,000 tokens. VERIFY BEFORE BILLING DECISIONS: the Bedrock rows
# are best-effort published estimates, not reconciled against an invoice
# (#153 Phase 0.5 origin — no per-token Bedrock cost data existed before this
# module). Keys are matched as a case-insensitive substring against the model
# id/name LangChain reports back — the bare Bedrock model id (bedrock:
# prefix stripped by quiz_shared.llm.factory) for Bedrock, or the OpenAI/
# OpenRouter model string otherwise. Checked longest-key-first so
# "gpt-4o-mini" wins over the "gpt-4o" prefix it contains.
_PRICE_TABLE_USD_PER_1M: dict[str, dict[str, float]] = {
    # Bedrock-hosted roles (raw ids from scripts/bedrock_raw_sample.py and
    # docs/testing/runs/153-phase-a/README.md, 2026-08-05/06 Bedrock stack).
    "moonshotai.kimi-k2.5": {"input": 0.60, "output": 2.50},
    "zai.glm-5": {"input": 0.50, "output": 1.50},
    "deepseek.v3.2": {"input": 0.28, "output": 1.10},
    # Canonical OpenAI direct-mode ids (app.feature_flags EVAL serve-time
    # role; quiz_shared.llm.factory.EVAL/EMBED defaults).
    "gpt-4o-mini": {"input": 0.15, "output": 0.60},
    "gpt-4o": {"input": 2.50, "output": 10.00},
    "text-embedding-3-small": {"input": 0.02, "output": 0.0},
    # #135 D10 answerability role, routed through OpenRouter
    # (quiz_shared.llm.factory.ANSWERABILITY = "deepseek-v4-flash" ->
    # OpenRouter slug "deepseek/deepseek-v4-flash").
    "deepseek-v4-flash": {"input": 0.15, "output": 0.60},
}
_PRICE_KEYS_BY_LENGTH_DESC = sorted(_PRICE_TABLE_USD_PER_1M, key=len, reverse=True)


def _price_for_model(model_id: str) -> dict[str, float] | None:
    """Best-effort price lookup by substring match; `None` when unpriced."""
    lowered = model_id.lower()
    for key in _PRICE_KEYS_BY_LENGTH_DESC:
        if key in lowered:
            return _PRICE_TABLE_USD_PER_1M[key]
    return None


class UsageRecorder:
    """Accumulates `{(stage, model): counts}` for one run.

    See module docstring for the concurrency caveat (plain dict, no lock).
    """

    def __init__(self) -> None:
        self._data: dict[tuple[str, str], dict[str, int]] = {}

    def record(
        self,
        stage: str,
        model: str,
        input_tokens: int | None,
        output_tokens: int | None,
    ) -> None:
        """Count one call. `None`/`None` tokens still counts the call, under
        `calls_without_usage` — a provider that omits usage data must show up
        as a visible gap, never silently vanish from the total."""
        bucket = self._data.setdefault(
            (stage, model),
            {
                "calls": 0,
                "input_tokens": 0,
                "output_tokens": 0,
                "calls_without_usage": 0,
            },
        )
        bucket["calls"] += 1
        if input_tokens is None and output_tokens is None:
            bucket["calls_without_usage"] += 1
            return
        bucket["input_tokens"] += input_tokens or 0
        bucket["output_tokens"] += output_tokens or 0

    def summary(self) -> dict[str, Any]:
        """JSON-able usage/cost summary, grouped by stage then model."""
        stages: dict[str, dict[str, Any]] = {}
        total_cost_cents_known = 0.0
        unpriced_models: set[str] = set()

        for (stage, model), bucket in self._data.items():
            entry = dict(bucket)
            price = _price_for_model(model)
            if price is not None:
                cost_cents = (
                    bucket["input_tokens"] / 1_000_000 * price["input"]
                    + bucket["output_tokens"] / 1_000_000 * price["output"]
                ) * 100
                entry["cost_cents"] = round(cost_cents, 4)
                total_cost_cents_known += cost_cents
            else:
                entry["cost_cents"] = None
                unpriced_models.add(model)
            stages.setdefault(stage, {})[model] = entry

        return {
            "stages": stages,
            "total_cost_cents_known": round(total_cost_cents_known, 4),
            "unpriced_models": sorted(unpriced_models),
            "coverage": COVERAGE_NOTE,
        }


def _extract_model_name(response: LLMResult) -> str | None:
    """Model id/name from `llm_output` (ChatOpenAI shape) or, when absent
    (ChatBedrockConverse sets no `llm_output` at all), from the first
    generation's `message.response_metadata` (both providers stamp
    `model_name` there — see quiz_shared's `chat_openai` module docstring and
    langchain_aws's `bedrock_converse.py`)."""
    if response.llm_output:
        name = response.llm_output.get("model_name") or response.llm_output.get("model")
        if name:
            return name
    for gen_list in response.generations:
        for gen in gen_list:
            message = getattr(gen, "message", None)
            if message is None:
                continue
            meta = getattr(message, "response_metadata", None) or {}
            name = meta.get("model_name") or meta.get("model")
            if name:
                return name
    return None


def _extract_usage(response: LLMResult) -> tuple[int | None, int | None]:
    """Token counts from `llm_output["token_usage"]` (ChatOpenAI's raw
    `prompt_tokens`/`completion_tokens`) or, when absent, summed from each
    generation's standardized `message.usage_metadata`
    (`input_tokens`/`output_tokens` — the shape ChatBedrockConverse sets and
    ChatOpenAI also mirrors). Returns `(None, None)` when neither shape is
    present so the caller can count the call without fabricating zero
    tokens."""
    if response.llm_output:
        usage = response.llm_output.get("token_usage") or response.llm_output.get("usage")
        if usage:
            input_tokens = usage.get("prompt_tokens", usage.get("input_tokens"))
            output_tokens = usage.get("completion_tokens", usage.get("output_tokens"))
            if input_tokens is not None or output_tokens is not None:
                return input_tokens or 0, output_tokens or 0

    total_in = total_out = 0
    found = False
    for gen_list in response.generations:
        for gen in gen_list:
            message = getattr(gen, "message", None)
            usage_metadata = getattr(message, "usage_metadata", None) if message else None
            if usage_metadata:
                found = True
                total_in += usage_metadata.get("input_tokens", 0) or 0
                total_out += usage_metadata.get("output_tokens", 0) or 0
    if found:
        return total_in, total_out
    return None, None


class UsageCallbackHandler(BaseCallbackHandler):
    """LangChain callback that records every chat call into a `UsageRecorder`.

    Registered via `quiz_shared.llm.factory.set_usage_handler` — see module
    docstring for how `chat_openai` attaches it.
    """

    def __init__(self, recorder: UsageRecorder) -> None:
        self._recorder = recorder

    def on_llm_end(self, response: LLMResult, **kwargs: Any) -> None:
        stage = current_stage.get()
        model = _extract_model_name(response) or "unknown-model"
        input_tokens, output_tokens = _extract_usage(response)
        self._recorder.record(stage, model, input_tokens, output_tokens)
