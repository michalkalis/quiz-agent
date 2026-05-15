"""ARQ WorkerSettings for quiz-pack-api (issue #33 Task 1.10).

Wires the Redis connection and the `process_order` task function. Phase 2
replaces only `tasks.py`; this file stays stable across all phases.
"""

from __future__ import annotations

from arq.connections import RedisSettings

from app.config import get_settings

from .tasks import process_order


class WorkerSettings:
    """ARQ worker configuration.

    max_tries=3 + job_timeout=600 gives the Phase-1 mitigation for R5:
    a stuck job is killed at 10 min and retried up to 3× before failing.
    """

    redis_settings: RedisSettings = RedisSettings.from_dsn(get_settings().redis_url)
    functions = [process_order]
    max_jobs: int = 2
    max_tries: int = 3
    job_timeout: int = 600
    keep_result: int = 86400
