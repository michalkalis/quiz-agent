"""Session-mode worker wiring (#172 — Session worker: custom packy v bete cez
subscription).

Why these matter: the mba worker runs the SAME image as the Fly one and is
distinguished only by env. Two things must hold before it takes a paid order
off the queue — it consumes the queue the deploy routed orders to, and it
refuses to boot in a session configuration that would either bill the API
(no subscription login) or burn the shared subscription quota on the judge
panel that #169 turned off for session runs.
"""

from __future__ import annotations

import importlib

import pytest
from app.config import get_settings
from quiz_shared.llm import factory as llm_factory


def _reloaded_worker_settings(monkeypatch: pytest.MonkeyPatch, **env: str):
    """Reimport app.worker.worker with `env` applied (class body reads settings)."""
    for key, value in env.items():
        monkeypatch.setenv(key, value)
    get_settings.cache_clear()
    import app.worker.worker as worker_module

    return importlib.reload(worker_module)


@pytest.fixture
def restore_worker_module():
    """Undo the module + settings reload so later tests see the real defaults."""
    yield
    get_settings.cache_clear()
    import app.worker.worker as worker_module

    importlib.reload(worker_module)


def test_worker_settings_read_queue_and_limits_from_env(
    monkeypatch: pytest.MonkeyPatch, restore_worker_module: None
) -> None:
    """WorkerSettings takes queue, concurrency and job budget from env.

    The mba worker needs its own queue, a single slot and a much longer budget
    (a `claude -p` pack run is far slower than the paid-API one). Hardcoded
    values here would mean the session worker either drains the Fly queue or
    gets its jobs killed mid-pack by the 1h default.
    """
    module = _reloaded_worker_settings(
        monkeypatch,
        WORKER_QUEUE_NAME="quiz-pack:session",
        WORKER_MAX_JOBS="1",
        WORKER_JOB_TIMEOUT_S="14400",
    )

    assert module.WorkerSettings.queue_name == "quiz-pack:session"
    assert module.WorkerSettings.max_jobs == 1
    assert module.WorkerSettings.job_timeout == 14400


def test_worker_settings_default_to_arq_defaults(
    monkeypatch: pytest.MonkeyPatch, restore_worker_module: None
) -> None:
    """With nothing set the worker behaves exactly as before #172 — the Fly
    deploy keeps consuming ARQ's default queue with two slots."""
    from arq.constants import default_queue_name

    for var in ("WORKER_QUEUE_NAME", "WORKER_MAX_JOBS", "WORKER_JOB_TIMEOUT_S"):
        monkeypatch.delenv(var, raising=False)
    module = _reloaded_worker_settings(monkeypatch)

    assert module.WorkerSettings.queue_name == default_queue_name
    assert module.WorkerSettings.max_jobs == 2
    assert module.WorkerSettings.job_timeout == 3600


@pytest.mark.asyncio
async def test_on_startup_session_mode_requires_subscription_login(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A session worker verifies the claude.ai login before doing anything else.

    Without this gate a worker whose CLI is logged out (or logged in with an
    API key) would pull a paid order off the queue and either die deep in the
    pipeline or bill the API the session gateway exists to avoid. The check
    runs before the DB/collaborator setup, so the failure names the real cause.
    """
    import app.worker.worker as worker_module
    from quiz_shared.llm import session_cli

    monkeypatch.setenv("LLM_GATEWAY", llm_factory.SESSION)
    monkeypatch.delenv("JUDGE_GATE", raising=False)
    monkeypatch.delenv("JUDGE_MODELS", raising=False)

    def _refuse() -> None:
        raise RuntimeError("The session gateway requires a Claude subscription login")

    monkeypatch.setattr(session_cli, "ensure_subscription_login", _refuse)

    with pytest.raises(RuntimeError, match="subscription login"):
        await worker_module.on_startup({})


@pytest.mark.asyncio
async def test_on_startup_session_mode_refuses_judges(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Judges on + session gateway is a refused configuration (#169).

    The judge panel added no measurable signal and ate most of the shared
    subscription quota, so `scripts/generate_pack.py` never runs it in session
    mode. The worker must enforce the same rule instead of quietly spending the
    founder's quota on it.
    """
    import app.worker.worker as worker_module
    from quiz_shared.llm import session_cli

    monkeypatch.setenv("LLM_GATEWAY", llm_factory.SESSION)
    monkeypatch.setenv("JUDGE_GATE", "1")
    monkeypatch.setattr(session_cli, "ensure_subscription_login", lambda: None)

    with pytest.raises(RuntimeError, match="JUDGE_GATE"):
        await worker_module.on_startup({})
