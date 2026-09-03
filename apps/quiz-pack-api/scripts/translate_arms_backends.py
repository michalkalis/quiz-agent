"""Per-arm translation backends for the #168 phase-1 arm test (T3, DD8).

Split out of ``translate_arms.py`` so each file stays inside the repo's
~300-line limit. Nothing here touches the database or writes files: an arm
takes source questions in, returns translated payloads (and what it cost) out.

Four routes, because the providers genuinely differ:

- **batch** — the DD7 adapter (``quiz_shared.llm.batch``). Opus 5 and
  Gemini 2.5 Pro have OpenRouter batch endpoints.
- **sync** — plain chat completions, used only when the provider has no batch
  endpoint for that exact model. OpenRouter's catalog advertises
  ``openai/gpt-4.1:batch`` but its batch API rejects the model, so the GPT-4.1
  arm lands here. The *model* never changes (standing rule: no substitutions);
  only the transport does, and loudly.
- **session** — #169: the Opus arm on the Claude Code subscription
  (``claude -p``) instead of OpenRouter. Same messages and parser as
  ``sync``; transport only, cost always 0 (not billed per call).
- **deepl** — the non-LLM arm. Synchronous SDK, one call per string, no batch
  path at all (DD7).

Only the player-facing payload is translated: ``question``,
``possible_answers``, ``correct_answer``, ``alternative_answers``,
``explanation``. ``topic`` / ``difficulty`` / ``source_url`` are rater-side
metadata and stay as they are, so all four arms are compared on the same
visible surface.
"""

from __future__ import annotations

import json
import os
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import Any, Optional

from langchain_core.messages import HumanMessage, SystemMessage
from quiz_shared.llm import batch as batch_api
from quiz_shared.llm import factory

LANGUAGE_NAMES = {"sk": "Slovak", "cs": "Czech"}
DEEPL_TARGETS = {"sk": "SK", "cs": "CS"}
#: Per-request completion cap for the LLM arms. Reasoning models (Gemini 2.5
#: Pro) spend "thinking" tokens inside this budget before the visible JSON, so
#: the old 2000 truncated 18/35 SK and 14/35 CS Gemini outputs mid-object in
#: the 2026-09-02 arm run (parse failed loud, as designed). 8000 leaves room
#: for thinking + a ~600-token payload; Opus/GPT-4.1 ignore the extra headroom.
MAX_TOKENS = 8000

#: The fields an arm must return. Kept in one place so the prompt, the DeepL
#: arm and the parser cannot drift apart.
PAYLOAD_FIELDS = (
    "question",
    "possible_answers",
    "correct_answer",
    "alternative_answers",
    "explanation",
)

_SYSTEM = (
    "You are a professional quiz localiser. You translate trivia questions so "
    "that a native speaker playing by voice in a car answers them exactly as an "
    "English speaker would."
)

_INSTRUCTIONS = """Translate this quiz question into {language}.

Rules:
- Return ONLY a JSON object with these keys: question, possible_answers, correct_answer, alternative_answers, explanation.
- Keep the structure identical: if possible_answers is an object, return an object with the SAME keys; if it is null, return null.
- correct_answer must stay the answer to the translated question, and for a multiple-choice question it must be the translated text of the same option.
- alternative_answers are extra spellings/forms a player might say out loud; return natural {language} variants (it may be a different number of entries than the source).
- Translate proper nouns only where {language} has an established form; otherwise keep the original.
- Never add, drop or change facts, numbers, dates or units.
- No commentary, no markdown fences.

Question JSON:
{payload}"""


@dataclass(frozen=True)
class ArmSpec:
    name: str
    #: OpenRouter slug or direct id for LLM arms; ``None`` for DeepL.
    model: Optional[str]
    route: str  # "batch" | "sync" | "session" | "deepl"


ARMS: dict[str, ArmSpec] = {
    "opus": ArmSpec("opus", "claude-opus-5", "batch"),
    "gemini": ArmSpec("gemini", "google/gemini-2.5-pro", "batch"),
    "gpt41": ArmSpec("gpt41", "gpt-4.1", "batch"),
    "deepl": ArmSpec("deepl", None, "deepl"),
}


@dataclass
class ArmRun:
    """What one (arm, language) run produced."""

    translations: dict[str, dict[str, Any]]  # question id -> translated payload
    #: USD as reported by the provider; ``None`` when unavailable (DD9 — never a
    #: fake 0, which would price batch translation as free).
    cost_usd: Optional[float]
    transport: str
    failures: list[str]


def _source_payload(q: Mapping[str, Any]) -> dict[str, Any]:
    return {k: q.get(k) for k in PAYLOAD_FIELDS}


def build_prompt(q: Mapping[str, Any], language: str) -> str:
    return _INSTRUCTIONS.format(
        language=LANGUAGE_NAMES[language],
        payload=json.dumps(_source_payload(q), ensure_ascii=False, indent=2),
    )


def _messages(q: Mapping[str, Any], language: str) -> list[dict[str, str]]:
    return [
        {"role": "system", "content": _SYSTEM},
        {"role": "user", "content": build_prompt(q, language)},
    ]


def parse_translation(text: str) -> dict[str, Any]:
    """Model text -> payload dict. Fails loud; a half-parsed row is worse than none."""
    cleaned = text.strip()
    if cleaned.startswith("```"):
        cleaned = cleaned.split("```")[1]
        if cleaned.lstrip().lower().startswith("json"):
            cleaned = cleaned.lstrip()[4:]
    start, end = cleaned.find("{"), cleaned.rfind("}")
    if start == -1 or end == -1:
        raise ValueError(f"no JSON object in model output: {text[:200]!r}")
    data = json.loads(cleaned[start : end + 1])
    missing = [f for f in PAYLOAD_FIELDS if f not in data]
    if missing:
        raise ValueError(f"translated payload missing {missing}")
    return data


# --------------------------------------------------------------------------
# LLM arms
# --------------------------------------------------------------------------


def _collect(
    questions: Sequence[Mapping[str, Any]],
    results: Mapping[str, str],
) -> tuple[dict[str, dict[str, Any]], list[str]]:
    out: dict[str, dict[str, Any]] = {}
    failures: list[str] = []
    for q in questions:
        qid = str(q["id"])
        text = results.get(qid)
        if text is None:
            failures.append(qid)
            continue
        try:
            out[qid] = parse_translation(text)
        except (ValueError, json.JSONDecodeError) as exc:
            failures.append(f"{qid}: {exc}")
    return out, failures


def run_batch_arm(
    spec: ArmSpec,
    questions: Sequence[Mapping[str, Any]],
    language: str,
    *,
    poll_interval: float = 20.0,
    timeout_s: float = 3600.0,
    log: Callable[[str], None] = print,
) -> ArmRun:
    """Submit + poll one batch. Falls back to sync transport (same model) when
    the provider has no batch endpoint for it — never to a different model."""
    requests = [
        batch_api.BatchRequest(
            custom_id=str(q["id"]),
            body={"messages": _messages(q, language), "max_tokens": MAX_TOKENS},
        )
        for q in questions
    ]
    try:
        job = batch_api.submit(spec.model, requests)
    except batch_api.BatchModelNotSupported as exc:
        log(
            f"  [{spec.name}/{language}] no batch endpoint for {spec.model!r} "
            f"({exc}) -> same model, synchronous transport"
        )
        return run_sync_arm(spec, questions, language, log=log)

    log(
        f"  [{spec.name}/{language}] batch {job.id} submitted ({len(requests)} requests)"
    )
    deadline = time.monotonic() + timeout_s
    while not job.is_terminal:
        if time.monotonic() > deadline:
            raise TimeoutError(f"batch {job.id} still {job.status} after {timeout_s}s")
        time.sleep(poll_interval)
        job = batch_api.poll(job.id)
        log(f"  [{spec.name}/{language}] {job.status} {dict(job.request_counts)}")

    if job.status != "completed":
        raise RuntimeError(f"batch {job.id} finished as {job.status}")

    results = batch_api.retrieve(job)
    texts = {r.custom_id: r.content for r in results if r.ok and r.content}
    translations, failures = _collect(questions, texts)
    return ArmRun(translations, job.cost_usd, "batch", failures)


def run_sync_arm(
    spec: ArmSpec,
    questions: Sequence[Mapping[str, Any]],
    language: str,
    *,
    log: Callable[[str], None] = print,
) -> ArmRun:
    """One chat completion per question, through the configured gateway.

    Cost is left ``None``: the per-call usage the SDK returns is tokens, not
    money, and inventing a price here would be exactly the fake number DD9
    forbids. The OpenRouter credits delta printed by the runner covers it.
    """
    client = factory.openai_client()
    model = factory.resolve_model(spec.model)
    texts: dict[str, str] = {}
    failures: list[str] = []
    for i, q in enumerate(questions, 1):
        qid = str(q["id"])
        try:
            resp = client.chat.completions.create(
                model=model,
                messages=_messages(q, language),
                max_tokens=MAX_TOKENS,
            )
            texts[qid] = resp.choices[0].message.content or ""
        except Exception as exc:
            failures.append(f"{qid}: {exc}")
        if i % 10 == 0:
            log(f"  [{spec.name}/{language}] {i}/{len(questions)} sync")
    translations, parse_failures = _collect(questions, texts)
    return ArmRun(translations, None, "sync", failures + parse_failures)


def uses_session_transport(model: Optional[str]) -> bool:
    """True when ``model`` runs on the Claude Code subscription (#169) — lets
    ``LLM_GATEWAY=session`` auto-route the existing ``opus`` arm (route
    ``"batch"``) to the subscription with no edit to ``ARMS``.

    Only Claude-family ids auto-route: an arm test compares *models*, so a
    Gemini/GPT arm must never be silently replaced by Claude (review of PR
    #67). Non-Claude arms under the session gateway are rejected by the
    caller instead."""
    if not model:
        return False
    if factory.is_session_model(model):
        return True
    return (
        factory.gateway() == factory.SESSION
        and factory.provider_for_model(model) == "anthropic"
    )


def session_gateway_rejects(model: Optional[str]) -> bool:
    """A non-Claude LLM arm cannot run while ``LLM_GATEWAY=session`` (#169):
    its batch/sync transport would resolve to a Claude tier and the arm would
    stop measuring the model it is named after. Fail loud, never substitute."""
    return (
        bool(model)
        and factory.gateway() == factory.SESSION
        and not uses_session_transport(model)
    )


def run_session_arm(
    spec: ArmSpec,
    questions: Sequence[Mapping[str, Any]],
    language: str,
    *,
    log: Callable[[str], None] = print,
) -> ArmRun:
    """One ``claude -p`` call per question on the Claude Code subscription.

    #169: transport swap only — same messages and ``parse_translation`` path
    as ``run_sync_arm``. ``session_model_for`` (not ``resolve_model``) picks
    the tier so this also works when called directly (explicit selection),
    with no OpenRouter/OpenAI key. Cost is always 0.
    """
    model_id = (
        spec.model
        if factory.is_session_model(spec.model)
        else factory.session_model_for(spec.model)
    )
    chat_model = factory.chat_openai(model_id)
    texts: dict[str, str] = {}
    failures: list[str] = []
    for i, q in enumerate(questions, 1):
        qid = str(q["id"])
        try:
            response = chat_model.invoke(
                [
                    SystemMessage(content=_SYSTEM),
                    HumanMessage(content=build_prompt(q, language)),
                ]
            )
            texts[qid] = factory.message_text(response)
        except Exception as exc:
            failures.append(f"{qid}: {exc}")
        if i % 10 == 0:
            log(f"  [{spec.name}/{language}] {i}/{len(questions)} session")
    translations, parse_failures = _collect(questions, texts)
    return ArmRun(translations, 0.0, "session", failures + parse_failures)


# --------------------------------------------------------------------------
# DeepL arm
# --------------------------------------------------------------------------

#: DeepL Free list price, USD per million characters (2026-09). Used only to
#: report what the arm would have cost on a paid plan.
DEEPL_USD_PER_MCHAR = 25.0


def run_deepl_arm(
    questions: Sequence[Mapping[str, Any]],
    language: str,
    *,
    log: Callable[[str], None] = print,
) -> ArmRun:
    """Translate each payload string with the DeepL SDK. No batch path (DD7)."""
    import deepl

    key = os.getenv("DEEPL_API_KEY")
    if not key:
        raise RuntimeError("DEEPL_API_KEY not set — see HP-1 in the #168 prompts file")
    translator = deepl.Translator(key)
    target = DEEPL_TARGETS[language]

    chars = 0
    translations: dict[str, dict[str, Any]] = {}
    failures: list[str] = []

    def _t(value: Any) -> Any:
        nonlocal chars
        if isinstance(value, str) and value.strip():
            chars += len(value)
            return translator.translate_text(value, target_lang=target).text
        if isinstance(value, list):
            return [_t(v) for v in value]
        if isinstance(value, dict):
            return {k: _t(v) for k, v in value.items()}
        return value

    for i, q in enumerate(questions, 1):
        qid = str(q["id"])
        try:
            translations[qid] = {k: _t(v) for k, v in _source_payload(q).items()}
        except Exception as exc:
            failures.append(f"{qid}: {exc}")
        if i % 10 == 0:
            log(f"  [deepl/{language}] {i}/{len(questions)}")

    cost = round(chars / 1_000_000 * DEEPL_USD_PER_MCHAR, 6)
    log(f"  [deepl/{language}] {chars} characters (~${cost} at list price)")
    return ArmRun(translations, cost, "deepl-sdk", failures)
