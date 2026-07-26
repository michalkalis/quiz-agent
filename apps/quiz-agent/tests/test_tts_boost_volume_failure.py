"""A failed volume boost must surface, not vanish into a warning line.

Why this matters: measured on real samples, raw tts-1 output peaks near
-11 dBFS and the boosted output near -0.2 dBFS. ``boost_volume`` catches every
exception and returns the raw bytes, so if ffmpeg is missing or broken in the
Fly image, every question plays ~11 dB quieter — fine in a quiet room,
inaudible over road noise, which is the entire product. The API still answers
200 with valid audio, so nothing else in the stack can notice. This repo has
already burned two rounds on silent-audio bugs (#104, #106) that nothing
surfaced.

The fallback itself is deliberate — a loudness problem must not hard-stop a
driving session — so this pins the other half: synthesis still succeeds, and
the failure reaches Sentry and the error log.
"""

import logging
from unittest.mock import patch

from app.tts import service as tts_service


def test_boost_failure_is_reported_and_still_returns_audio(caplog):
    """Undecodable audio (what a broken/missing ffmpeg looks like from here)."""
    raw = b"not-actually-mp3-bytes"

    with (
        patch.object(tts_service.sentry_sdk, "capture_message") as mock_capture,
        caplog.at_level(logging.ERROR, logger="app.tts.service"),
    ):
        result = tts_service.boost_volume(raw)

    # The session keeps its audio — degraded, never dropped.
    assert result == raw

    # Sentry sees it at error level, not warning, so it pages instead of
    # sitting in a log nobody reads.
    mock_capture.assert_called_once()
    message, kwargs = mock_capture.call_args[0][0], mock_capture.call_args[1]
    assert kwargs["level"] == "error"
    # The alert has to be actionable on its own: what broke and why it matters.
    assert "volume boost failed" in message.lower()
    assert "ffmpeg" in message.lower()

    assert [r for r in caplog.records if r.levelno >= logging.ERROR], (
        "the boost failure must be logged at ERROR, not swallowed at warning"
    )
