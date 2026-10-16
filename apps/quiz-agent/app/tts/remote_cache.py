"""TTS audio in a private R2 bucket, shared by every quiz-agent machine (#207.20).

The local disk cache (``TTSCache``) becomes a per-machine L1 on the ephemeral
rootfs; this is the durable L2. Every synthesized question and static feedback
clip is written here, so a fresh machine (deploy, second machine, host move)
serves cached questions with zero ElevenLabs calls — those credits are scarce
(Starter plan, no top-up) and ~185 credits per first read of a question.

Env (Fly secrets on ``quiz-agent-api``): ``R2_ENDPOINT`` (shared with voice
samples), ``TTS_R2_ACCESS_KEY_ID`` / ``TTS_R2_SECRET_ACCESS_KEY`` (token
scoped to this bucket only), ``TTS_R2_BUCKET``. Missing → no L2 (dev/tests),
exactly the old behaviour.

boto3 is blocking; every call runs in a worker thread. A failing R2 never
fails a request: reads count as a miss, writes are logged.
"""

from __future__ import annotations

import asyncio
import logging
import os

logger = logging.getLogger(__name__)

REQUIRED_ENV = (
    "R2_ENDPOINT",
    "TTS_R2_ACCESS_KEY_ID",
    "TTS_R2_SECRET_ACCESS_KEY",
    "TTS_R2_BUCKET",
)


class R2AudioStore:
    def __init__(self, client, bucket: str) -> None:
        self._client = client
        self._bucket = bucket

    @classmethod
    def from_env(cls) -> "R2AudioStore | None":
        if any(not os.environ.get(name) for name in REQUIRED_ENV):
            return None
        import boto3
        from botocore.config import Config

        client = boto3.client(
            "s3",
            endpoint_url=os.environ["R2_ENDPOINT"],
            aws_access_key_id=os.environ["TTS_R2_ACCESS_KEY_ID"],
            aws_secret_access_key=os.environ["TTS_R2_SECRET_ACCESS_KEY"],
            config=Config(
                signature_version="s3v4",
                connect_timeout=3,
                read_timeout=5,
                retries={"max_attempts": 2},
            ),
            region_name="auto",
        )
        return cls(client, os.environ["TTS_R2_BUCKET"])

    def _get(self, key: str) -> bytes | None:
        try:
            obj = self._client.get_object(Bucket=self._bucket, Key=key)
        except self._client.exceptions.NoSuchKey:
            return None
        return obj["Body"].read()

    async def get(self, key: str) -> bytes | None:
        try:
            return await asyncio.to_thread(self._get, key)
        except Exception as e:  # noqa: BLE001 — a miss, never a failed request
            logger.warning("TTS R2 read failed (%s): %s", key, type(e).__name__)
            return None

    async def put(self, key: str, data: bytes) -> None:
        try:
            await asyncio.to_thread(
                self._client.put_object,
                Bucket=self._bucket,
                Key=key,
                Body=data,
                ContentType="audio/mpeg",
            )
        except Exception as e:  # noqa: BLE001 — L1 still has it
            logger.warning("TTS R2 write failed (%s): %s", key, type(e).__name__)
