"""Worker survives a dropped Redis connection and keeps a real heartbeat (#193).

Incident 2026-10-08: the mba session worker reaches prod Redis through a
`fly proxy` tunnel. One "Connection closed by server" inside ARQ's poll loop
(`zrangebyscore`) killed the process, and it lay dead ~20 h. These tests replay
that exact failure against a tiny fake Redis server, with the real
WorkerSettings, and pin the heartbeat cadence the prod monitor relies on.
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator

import pytest
import pytest_asyncio
from app.config import WORKER_HEALTH_CHECK_INTERVAL_S
from app.worker.worker import WorkerSettings, _worker_redis_settings
from arq.connections import RedisSettings, create_pool
from redis.exceptions import ConnectionError as RedisConnectionError


class _FlakyRedis:
    """Answers PING with PONG and anything else with an empty array, except
    that after `drop_next()` it hangs up on the next command it reads — what
    the tunnel did to the worker."""

    def __init__(self) -> None:
        self._drop = False
        self.port = 0

    def drop_next(self) -> None:
        self._drop = True

    async def _serve(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        # One RESP command = "*<n>" then n "$<len>" + value line pairs; redis-py
        # pipelines its CLIENT SETINFO handshake, so answer each command.
        while header := await reader.readline():
            argv = [await self._bulk(reader) for _ in range(int(header[1:]))]
            if self._drop:
                self._drop = False
                break
            writer.write(b"+PONG\r\n" if argv[0].upper() == b"PING" else b"*0\r\n")
            await writer.drain()
        writer.close()

    @staticmethod
    async def _bulk(reader: asyncio.StreamReader) -> bytes:
        await reader.readline()  # $<len>
        return (await reader.readline()).rstrip(b"\r\n")


@pytest_asyncio.fixture
async def flaky_redis() -> AsyncIterator[_FlakyRedis]:
    fake = _FlakyRedis()
    server = await asyncio.start_server(fake._serve, "127.0.0.1", 0)
    fake.port = server.sockets[0].getsockname()[1]
    async with server:
        yield fake


async def _poll_after_drop(fake: _FlakyRedis, settings: RedisSettings) -> list:
    pool = await create_pool(settings)
    try:
        fake.drop_next()
        return await pool.zrangebyscore("quiz-pack:session", min=float("-inf"), max=0)
    finally:
        await pool.aclose()


async def test_worker_redis_reconnects_after_server_drops_connection(
    flaky_redis: _FlakyRedis,
) -> None:
    settings = _worker_redis_settings(f"redis://127.0.0.1:{flaky_redis.port}/0")

    assert await _poll_after_drop(flaky_redis, settings) == []


async def test_arq_default_settings_die_on_the_same_drop(flaky_redis: _FlakyRedis) -> None:
    # Why the worker needs its own settings: with ARQ/redis-py defaults the
    # identical drop raises straight out of the poll loop — the 20 h outage.
    settings = RedisSettings.from_dsn(f"redis://127.0.0.1:{flaky_redis.port}/0")

    with pytest.raises(RedisConnectionError):
        await _poll_after_drop(flaky_redis, settings)


def test_worker_uses_the_resilient_settings_and_minute_heartbeat() -> None:
    # The admin heartbeat endpoint dates the last write from the key's TTL
    # assuming this cadence; ARQ's 1 h default would hide a dead worker for
    # up to an hour.
    assert WorkerSettings.redis_settings.retry is not None
    assert RedisConnectionError in WorkerSettings.redis_settings.retry_on_error
    assert WorkerSettings.health_check_interval == WORKER_HEALTH_CHECK_INTERVAL_S == 60
