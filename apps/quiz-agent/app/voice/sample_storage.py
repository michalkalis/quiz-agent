"""Private R2 storage for the car answer recordings (issue #197, track 197.2).

Same Cloudflare R2 config pattern as quiz-pack-api's
``image_generation/r2_uploader.py`` (boto3 S3 client on the R2 endpoint), but a
separate, PRIVATE bucket: these are voice recordings, never served publicly.
The replay script reads them through short-lived presigned URLs.

Env (Fly secrets on ``quiz-agent-api``; checked when a sample is stored or
listed, never at boot, so a deploy without them still serves the quiz):

- ``R2_ENDPOINT``            https://<account>.r2.cloudflarestorage.com
- ``R2_ACCESS_KEY_ID``       R2 API token scoped to the voice-samples bucket
- ``R2_SECRET_ACCESS_KEY``
- ``VOICE_SAMPLES_R2_BUCKET`` the private bucket name (e.g. ``trubbo-voice-samples``)

boto3 is imported lazily: only the founder's uploads ever touch this module, so
the quiz hot path never pays its import memory.
"""

from __future__ import annotations

import os
from typing import Protocol

REQUIRED_ENV = (
    "R2_ENDPOINT",
    "R2_ACCESS_KEY_ID",
    "R2_SECRET_ACCESS_KEY",
    "VOICE_SAMPLES_R2_BUCKET",
)
KEY_PREFIX = "voice-samples"


class StorageNotConfigured(RuntimeError):
    """The R2 env for voice samples is missing — the route answers 503."""


class VoiceSampleStorage(Protocol):
    def put(self, key: str, data: bytes, content_type: str) -> None: ...

    def presigned_url(self, key: str, expires_seconds: int = 3600) -> str: ...


class R2VoiceSampleStorage:
    """boto3-backed storage; the client is built on first use."""

    def __init__(self) -> None:
        self._client = None
        self._bucket: str | None = None

    def _ensure(self):
        if self._client is not None:
            return self._client
        missing = [name for name in REQUIRED_ENV if not os.environ.get(name)]
        if missing:
            raise StorageNotConfigured(
                "voice sample storage is not configured; missing env: "
                + ", ".join(missing)
            )
        import boto3
        from botocore.config import Config

        self._bucket = os.environ["VOICE_SAMPLES_R2_BUCKET"]
        self._client = boto3.client(
            "s3",
            endpoint_url=os.environ["R2_ENDPOINT"],
            aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"],
            aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"],
            config=Config(signature_version="s3v4"),
            region_name="auto",
        )
        return self._client

    def put(self, key: str, data: bytes, content_type: str) -> None:
        client = self._ensure()
        client.put_object(
            Bucket=self._bucket, Key=key, Body=data, ContentType=content_type
        )

    def presigned_url(self, key: str, expires_seconds: int = 3600) -> str:
        client = self._ensure()
        return client.generate_presigned_url(
            "get_object",
            Params={"Bucket": self._bucket, "Key": key},
            ExpiresIn=expires_seconds,
        )
