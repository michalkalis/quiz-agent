"""Fake ``claude`` CLI binary for #169 session-gateway tests.

``session_cli.ChatClaudeSession`` shells out to the real ``claude`` binary.
Tests must never invoke the real CLI (it would bill the subscription /
session quota and require an interactive login), so this installs a small
Python script named ``claude`` on ``PATH`` that plays the same envelope
contract: ``claude auth status`` returns a JSON login status, and
``claude -p ...`` reads the prompt from stdin, records the invocation
(argv + stdin + selected env vars) to a JSON file the test can inspect, and
prints an ``--output-format json`` envelope.

Behaviour is steered per-test via a JSON control file (env var
``FAKE_CLAUDE_CONTROL``) rather than argv, so a test can flip auth status,
the response envelope, or a nonzero exit without touching PATH again.
"""

from __future__ import annotations

import json
import os
import stat
import textwrap
from pathlib import Path
from typing import Any

# Mirrors session_cli._SCRUBBED_ENV — the fake binary records whichever of
# these survive into its own environment, so a test can assert on absence.
_RECORDED_ENV_KEYS = (
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_BASE_URL",
    "CLAUDECODE",
    "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
)

_SCRIPT = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import json
    import os
    import sys

    RECORDED_ENV_KEYS = %(recorded_keys)r


    def _load_control():
        path = os.environ.get("FAKE_CLAUDE_CONTROL")
        if path and os.path.exists(path):
            with open(path) as f:
                return json.load(f)
        return {}


    def main():
        argv = sys.argv[1:]
        control = _load_control()

        if argv[:2] == ["auth", "status"]:
            auth = control.get("auth", {"loggedIn": True, "authMethod": "claude.ai"})
            print(json.dumps(auth))
            return control.get("auth_exit_code", 0)

        prompt = sys.stdin.read()

        record_path = os.environ.get("FAKE_CLAUDE_RECORD")
        if record_path:
            record = {
                "argv": argv,
                "stdin": prompt,
                "env": {k: os.environ[k] for k in RECORDED_ENV_KEYS if k in os.environ},
            }
            with open(record_path, "w") as f:
                json.dump(record, f)

        stderr_text = control.get("stderr", "")
        if stderr_text:
            print(stderr_text, file=sys.stderr)

        response = control.get("response")
        if response is None:
            response = {
                "result": "ok",
                "usage": {"input_tokens": 10, "output_tokens": 5},
                "modelUsage": {},
                "is_error": False,
                "subtype": "success",
            }
        print(json.dumps(response))
        return control.get("exit_code", 0)


    if __name__ == "__main__":
        sys.exit(main())
    """
) % {"recorded_keys": _RECORDED_ENV_KEYS}


def install_fake_claude(tmp_path: Path) -> Path:
    """Write the fake ``claude`` script under ``tmp_path/bin`` and return its dir.

    Callers still need to prepend the returned dir to ``PATH`` (via
    ``monkeypatch``) and point ``FAKE_CLAUDE_CONTROL``/``FAKE_CLAUDE_RECORD``
    at files under ``tmp_path`` as needed per test.
    """
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    script_path = bin_dir / "claude"
    script_path.write_text(_SCRIPT)
    script_path.chmod(
        script_path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH
    )
    return bin_dir


def write_control(path: Path, **control: Any) -> None:
    """Write the JSON control file the fake binary reads on every invocation."""
    path.write_text(json.dumps(control))


def read_record(path: Path) -> dict:
    """Read back what the fake ``-p`` invocation recorded (argv/stdin/env)."""
    return json.loads(path.read_text())


def default_response(**overrides: Any) -> dict:
    """A minimal successful ``--output-format json`` envelope, override-able."""
    base = {
        "result": "ok",
        "usage": {"input_tokens": 10, "output_tokens": 5},
        "modelUsage": {"claude-opus-5": {}},
        "is_error": False,
        "subtype": "success",
    }
    base.update(overrides)
    return base


def setup_fake_claude(
    monkeypatch, tmp_path: Path, *, control: dict | None = None
) -> tuple[Path, Path]:
    """Install the fake binary, wire PATH + control/record env, reset login cache.

    Returns ``(control_path, record_path)``. Import ``session_cli`` lazily at
    the call site is not required — this only touches env/PATH; it also
    resets ``session_cli._login_checked`` so each test starts with a fresh
    auth check regardless of what a previous test did.
    """
    from quiz_shared.llm import session_cli

    bin_dir = install_fake_claude(tmp_path)
    monkeypatch.setenv("PATH", f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}")

    control_path = tmp_path / "control.json"
    write_control(
        control_path,
        **(control or {"auth": {"loggedIn": True, "authMethod": "claude.ai"}}),
    )
    monkeypatch.setenv("FAKE_CLAUDE_CONTROL", str(control_path))

    record_path = tmp_path / "record.json"
    monkeypatch.setenv("FAKE_CLAUDE_RECORD", str(record_path))

    monkeypatch.setattr(session_cli, "_login_checked", False)
    return control_path, record_path
