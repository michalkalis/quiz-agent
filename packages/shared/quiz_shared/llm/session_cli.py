"""Claude Code subscription transport for the shared LLM factory (#169).

``session:<alias>`` model ids (``fable`` | ``opus`` | ``sonnet`` | ``haiku``)
run ``claude -p`` (Claude Code headless mode) as a subprocess instead of
calling a paid API, so developer-side pipeline runs land on the Claude Code
subscription. This is a *transport only*: prompts, parsers, guards and
feature flags are the shared prod code — the backend API pipeline stays the
source of truth and the session path mirrors it 1:1 (founder, 2026-09-02).
Dev-only: never configured on Fly.

Policy (verified 2026-09-02, code.claude.com/docs/en/headless + /authentication
+ /errors): headless ``claude -p`` on a subscription login is supported for
the subscriber's own scripts and counts against the subscription's
session/weekly limits. The subprocess env is scrubbed of ``ANTHROPIC_API_KEY``
and friends and the login is checked once per process, so a session run can
never silently bill the API instead.

Surface implemented = exactly what call sites use (survey 2026-09-02):
``ainvoke(str | [HumanMessage])`` → ``AIMessage`` with ``content`` /
``usage_metadata`` / ``response_metadata``, and
``with_structured_output(model, method="function_calling", include_raw=True)``
(one tool) via ``bind_tools`` → ``--json-schema`` → ``tool_calls``.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import subprocess
import tempfile
from collections.abc import Sequence
from typing import Any

from langchain_core.language_models import BaseChatModel
from langchain_core.messages import AIMessage, BaseMessage, SystemMessage
from langchain_core.outputs import ChatGeneration, ChatResult
from langchain_core.utils.function_calling import convert_to_openai_tool
from pydantic import ConfigDict

logger = logging.getLogger(__name__)

SESSION_PREFIX = "session:"
SESSION_ALIASES = ("fable", "opus", "sonnet", "haiku")
WEB_TOOLS = "WebSearch,WebFetch"
DEFAULT_TIMEOUT_S = 300.0
DEFAULT_CONCURRENCY = 4

# Never let the headless subprocess see API-key auth or the parent session's
# markers: a key in the env would make ``claude`` bill the API (the opposite
# of the point), and CLAUDECODE would mark this as a nested tool call.
_SCRUBBED_ENV = (
    "CLAUDECODE",
    "CLAUDE_CODE_ENTRYPOINT",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_BASE_URL",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
)


def session_alias(model_id: str) -> str:
    """``session:opus`` → ``opus``; rejects unknown aliases loudly."""
    alias = model_id.removeprefix(SESSION_PREFIX)
    if alias not in SESSION_ALIASES:
        raise ValueError(
            f"Unknown session model {model_id!r}; expected session:<"
            f"{'|'.join(SESSION_ALIASES)}>"
        )
    return alias


def build_command(
    alias: str,
    *,
    max_turns: int,
    tools: str = "",
    json_schema: dict | None = None,
    system_prompt: str | None = None,
) -> list[str]:
    """``claude -p`` argv. Prompt goes over stdin (no argv length limits).

    ``--setting-sources ""`` + an empty strict MCP config drop the repo's
    CLAUDE.md/skills/MCP servers from the system prompt — measured 2026-09-02
    as ~6.5k vs ~39k input tokens per call, i.e. the difference between a
    cheap transport and burning the weekly quota on boilerplate.
    """
    cmd = [
        "claude",
        "-p",
        "--model",
        alias,
        "--output-format",
        "json",
        "--max-turns",
        str(max_turns),
        "--no-session-persistence",
        "--setting-sources",
        "",
        "--strict-mcp-config",
        "--mcp-config",
        '{"mcpServers":{}}',
        "--tools",
        tools,
    ]
    if tools:
        cmd += ["--allowedTools", tools]
    if json_schema is not None:
        cmd += ["--json-schema", json.dumps(json_schema)]
    if system_prompt:
        cmd += ["--system-prompt", system_prompt]
    return cmd


def subprocess_env() -> dict[str, str]:
    env = dict(os.environ)
    for key in _SCRUBBED_ENV:
        env.pop(key, None)
    return env


_login_checked = False


def ensure_subscription_login() -> None:
    """Fail loud unless ``claude`` is on PATH and logged in via claude.ai.

    Checked once per process. API-key auth is deliberately refused: the
    whole point of the session gateway is that these runs never bill the API.
    """
    global _login_checked
    if _login_checked:
        return
    try:
        proc = subprocess.run(
            ["claude", "auth", "status"],
            capture_output=True,
            text=True,
            env=subprocess_env(),
            timeout=30,
            check=False,
        )
    except FileNotFoundError as exc:
        raise RuntimeError(
            "LLM_GATEWAY=session needs the `claude` CLI (Claude Code) on PATH. "
            "Install it or unset LLM_GATEWAY."
        ) from exc
    try:
        status = json.loads(proc.stdout)
    except json.JSONDecodeError:
        status = {}
    if not status.get("loggedIn") or status.get("authMethod") != "claude.ai":
        detail = (proc.stdout or proc.stderr).strip()[:200]
        raise RuntimeError(
            "The session gateway requires a Claude subscription login "
            f"(`claude auth status` → {detail!r}). Run `claude` and log in with "
            "claude.ai; API-key auth is refused so session runs never bill the API."
        )
    _login_checked = True


def parse_result(stdout: str, stderr: str, returncode: int) -> dict[str, Any]:
    """The ``--output-format json`` envelope, or a loud error."""
    if returncode != 0:
        raise RuntimeError(
            f"claude -p exited {returncode}: {stderr.strip()[-500:] or stdout.strip()[-500:]}"
        )
    try:
        data = json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(
            f"claude -p returned non-JSON output: {stdout[:300]!r}"
        ) from exc
    if not isinstance(data, dict):
        raise TypeError(f"claude -p returned unexpected JSON: {stdout[:300]!r}")
    if data.get("is_error") or data.get("subtype") not in (None, "success"):
        raise RuntimeError(
            f"claude -p failed: subtype={data.get('subtype')!r} "
            f"result={str(data.get('result'))[:300]!r}"
        )
    return data


def _text_of(content: Any) -> str:
    if isinstance(content, str):
        return content
    return "".join(
        block.get("text", "") if isinstance(block, dict) else str(block)
        for block in content
    )


def to_chat_result(
    alias: str, data: dict[str, Any], tool_name: str | None
) -> ChatResult:
    usage = data.get("usage") or {}
    input_tokens = int(
        (usage.get("input_tokens") or 0)
        + (usage.get("cache_creation_input_tokens") or 0)
        + (usage.get("cache_read_input_tokens") or 0)
    )
    output_tokens = int(usage.get("output_tokens") or 0)
    model_name = SESSION_PREFIX + alias
    tool_calls = []
    structured = data.get("structured_output")
    if tool_name and isinstance(structured, dict):
        tool_calls.append(
            {
                "name": tool_name,
                "args": structured,
                "id": "session_call_1",
                "type": "tool_call",
            }
        )
    elif tool_name:
        logger.warning("session gateway: no structured_output for tool %s", tool_name)
    message = AIMessage(
        content=data.get("result") or "",
        tool_calls=tool_calls,
        usage_metadata={
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "total_tokens": input_tokens + output_tokens,
        },
        response_metadata={
            "model_name": model_name,
            "canonical_models": sorted((data.get("modelUsage") or {}).keys()),
            "session_id": data.get("session_id"),
            "num_turns": data.get("num_turns"),
        },
    )
    return ChatResult(
        generations=[ChatGeneration(message=message)],
        llm_output={
            "model_name": model_name,
            "usage": {"input_tokens": input_tokens, "output_tokens": output_tokens},
        },
    )


_semaphores: dict[int, asyncio.Semaphore] = {}


def _semaphore() -> asyncio.Semaphore:
    key = id(asyncio.get_running_loop())
    sem = _semaphores.get(key)
    if sem is None:
        limit = int(os.getenv("LLM_SESSION_CONCURRENCY") or DEFAULT_CONCURRENCY)
        sem = _semaphores[key] = asyncio.Semaphore(limit)
    return sem


class ChatClaudeSession(BaseChatModel):
    """LangChain chat model backed by a ``claude -p`` subprocess."""

    model_config = ConfigDict(extra="ignore")

    alias: str
    web: bool = False
    max_turns: int = 1
    timeout: float = DEFAULT_TIMEOUT_S
    # Accepted for call-site compatibility; the CLI always uses the model max.
    max_tokens: int | None = None

    @property
    def _llm_type(self) -> str:
        return "claude-session-cli"

    @property
    def _identifying_params(self) -> dict[str, Any]:
        return {"alias": self.alias, "web": self.web, "max_turns": self.max_turns}

    def bind_tools(
        self, tools: Sequence[Any], *, tool_choice: Any = None, **kwargs: Any
    ):
        """Exactly one tool = the structured-output schema (``--json-schema``)."""
        if len(tools) != 1:
            raise ValueError(
                f"ChatClaudeSession supports exactly one tool (structured output); got {len(tools)}"
            )
        spec = convert_to_openai_tool(tools[0])["function"]
        return self.bind(
            session_tool={
                "name": spec["name"],
                "schema": spec.get("parameters") or {"type": "object"},
            }
        )

    def _prepare(
        self, messages: list[BaseMessage], kwargs: dict[str, Any]
    ) -> tuple[list[str], str, str | None]:
        system = "\n\n".join(
            _text_of(m.content) for m in messages if isinstance(m, SystemMessage)
        )
        prompt = "\n\n".join(
            _text_of(m.content) for m in messages if not isinstance(m, SystemMessage)
        )
        tool = kwargs.get("session_tool")
        # A --json-schema answer is delivered as a tool turn → needs ≥ 2 turns.
        max_turns = max(self.max_turns, 2) if tool else self.max_turns
        cmd = build_command(
            self.alias,
            max_turns=max_turns,
            tools=WEB_TOOLS if self.web else "",
            json_schema=tool["schema"] if tool else None,
            system_prompt=system or None,
        )
        return cmd, prompt, (tool["name"] if tool else None)

    def _generate(self, messages, stop=None, run_manager=None, **kwargs) -> ChatResult:
        cmd, prompt, tool_name = self._prepare(messages, kwargs)
        ensure_subscription_login()
        proc = subprocess.run(
            cmd,
            input=prompt,
            capture_output=True,
            text=True,
            env=subprocess_env(),
            cwd=tempfile.gettempdir(),
            timeout=self.timeout,
            check=False,
        )
        return to_chat_result(
            self.alias,
            parse_result(proc.stdout, proc.stderr, proc.returncode),
            tool_name,
        )

    async def _agenerate(
        self, messages, stop=None, run_manager=None, **kwargs
    ) -> ChatResult:
        cmd, prompt, tool_name = self._prepare(messages, kwargs)
        ensure_subscription_login()
        async with _semaphore():
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                env=subprocess_env(),
                cwd=tempfile.gettempdir(),
            )
            try:
                out, err = await asyncio.wait_for(
                    proc.communicate(prompt.encode()), timeout=self.timeout
                )
            except TimeoutError:
                proc.kill()
                await proc.wait()
                raise TimeoutError(
                    f"claude -p ({self.alias}) exceeded {self.timeout:.0f}s"
                ) from None
        data = parse_result(out.decode(), err.decode(), proc.returncode)
        return to_chat_result(self.alias, data, tool_name)
