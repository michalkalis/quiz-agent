"""#207 (207.23): what a player typed or said never reaches Sentry.

The privacy policy names Sentry only for crash and error diagnostics, so an
answer, transcript or pack topic landing there would be data we never told
anyone we send. The scenarios drive the real SDK with the production options
(`quiz_shared.sentry_privacy`) through a capturing transport and assert the
player's words appear nowhere in what would have left the server.

They run in a child process: `sentry_sdk.init` patches Starlette and FastAPI
for the life of the interpreter, which would trip later tests that mock Sentry.
"""

from __future__ import annotations

import json
import subprocess
import sys
import textwrap

import pytest

PLAYER_TEXT = "Bratislava je moje tajomstvo"

_SCENARIOS = textwrap.dedent(
    """
    import json, logging, sys
    import sentry_sdk
    from fastapi import FastAPI, Request
    from fastapi.testclient import TestClient
    from sentry_sdk.integrations.logging import LoggingIntegration
    from sentry_sdk.transport import Transport
    from quiz_shared.sentry_privacy import sentry_privacy_options, user_text_log

    PLAYER_TEXT = sys.stdin.read()  # not argv: Sentry reports argv
    sent = []

    class Capture(Transport):
        def capture_envelope(self, envelope):
            for item in envelope.items:
                sent.append(item.payload.get_bytes().decode("utf-8", "replace"))

    # Same shape as apps/quiz-agent/app/main.py and quiz-pack-api's init.
    sentry_sdk.init(
        dsn="https://public@example.invalid/1",
        transport=Capture(),
        enable_logs=True,
        integrations=[LoggingIntegration(sentry_logs_level=logging.WARNING)],
        **sentry_privacy_options(),
    )

    def flushed():
        sentry_sdk.flush()
        out = "\\n".join(sent)
        sent.clear()
        return out

    result = {}

    # 1. A 500 while grading: request body + frame locals hold the answer.
    app = FastAPI()

    @app.post("/submit")
    async def submit(request: Request):
        user_answer = (await request.json())["answer"]
        raise RuntimeError(f"grader exploded after {len(user_answer)} chars")

    TestClient(app, raise_server_exceptions=False).post(
        "/submit", json={"answer": PLAYER_TEXT}
    )
    result["crash"] = flushed()

    # 2. Player text logged for live debugging, then an ordinary error.
    user_text_log.info("Transcribed: %r", PLAYER_TEXT)
    user_text_log.warning("Rejected transcript: %r", PLAYER_TEXT)
    logging.getLogger("app.voice").error("transcription failed (chars=%d)", 28)
    result["logs"] = flushed()

    # 3. An integration attaches a body anyway: before_send drops it.
    with sentry_sdk.new_scope() as scope:
        scope.add_event_processor(
            lambda event, hint: {**event, "request": {"data": {"a": PLAYER_TEXT}}}
        )
        sentry_sdk.capture_message("submit failed")
    result["attached_body"] = flushed()

    print(json.dumps(result))
    """
)


@pytest.fixture(scope="module")
def sent() -> dict[str, str]:
    proc = subprocess.run(
        [sys.executable, "-c", _SCENARIOS],
        input=PLAYER_TEXT,
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert proc.returncode == 0, proc.stderr
    return json.loads(proc.stdout.strip().splitlines()[-1])


def test_crash_while_grading_carries_no_answer_body_or_locals(sent):
    """A 500 in the submit path must not ship the request body (the typed
    answer) or the frame's local variables (where `user_answer` lives)."""
    assert "grader exploded" in sent["crash"], "the error itself still reaches Sentry"
    assert PLAYER_TEXT not in sent["crash"]


def test_user_text_logger_stays_out_of_events_breadcrumbs_and_logs(sent):
    """Player text logged for live debugging stays in stdout only: not as a
    breadcrumb on the next error, not in Sentry Logs, not as an event."""
    assert "transcription failed" in sent["logs"], "ordinary errors still go"
    assert PLAYER_TEXT not in sent["logs"]


def test_body_attached_by_an_integration_is_dropped(sent):
    """Defence in depth: should an integration attach a body anyway,
    `before_send` removes it."""
    assert "submit failed" in sent["attached_body"]
    assert PLAYER_TEXT not in sent["attached_body"]
