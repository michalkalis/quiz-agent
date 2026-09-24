"""ElevenLabs Scribe v2 batch speech-to-text (#184 track C).

whisper-1 hallucinates on silence and short clips, and gives no per-word
confidence — so a passenger's half-sentence or a burst of road noise picked up
after the answer lands in the transcript with nothing to distinguish it from
the answer itself. Scribe v2 batch returns per-word ``logprob``, which lets the
trailing garbage run be cut, and accepts ``keyterms`` so MCQ option texts bias
the recogniser toward the words the player is actually likely to say.

Raw httpx on purpose (the ``elevenlabs`` SDK is not a dependency, and the
Dockerfile pip list must stay 1:1 with pyproject) — same pattern as
``app/tts/providers.py``.
"""

from __future__ import annotations

import logging
import os
from statistics import fmean
from typing import Any, Optional

import httpx

from .transcriber import TranscriptionResult

logger = logging.getLogger(__name__)

ELEVENLABS_STT_URL = "https://api.elevenlabs.io/v1/speech-to-text"

# A whole answer clip is uploaded and transcribed before the call returns; a
# timeout here is not fatal — it trips the OpenAI fallback.
SCRIBE_TIMEOUT_SECONDS = 30.0

# Keyterm constraints published by ElevenLabs: max 1000 terms, each under 50
# characters and at most 5 words, with these characters rejected outright.
KEYTERM_MAX_COUNT = 1000
KEYTERM_MAX_CHARS = 49
KEYTERM_MAX_WORDS = 5
KEYTERM_FORBIDDEN_CHARS = "<>{}[]"


class ScribeUnavailable(RuntimeError):
    """Scribe could not produce a transcript — the caller must fall back.

    Typed so that a provider outage, a missing key or an exhausted credit pool
    are all one branch at the call site, distinct from a genuine bug.
    """


def sanitize_keyterms(keyterms: Optional[list[str]]) -> list[str]:
    """Drop terms ElevenLabs would reject, so one bad option never 422s the call."""
    cleaned: list[str] = []
    seen: set[str] = set()
    for raw in keyterms or []:
        if not raw:
            continue
        term = raw
        for ch in KEYTERM_FORBIDDEN_CHARS:
            term = term.replace(ch, " ")
        term = " ".join(term.split())
        if not term:
            continue
        if len(term.split(" ")) > KEYTERM_MAX_WORDS:
            continue
        if len(term) > KEYTERM_MAX_CHARS:
            continue
        key = term.lower()
        if key in seen:
            continue
        seen.add(key)
        cleaned.append(term)
        if len(cleaned) >= KEYTERM_MAX_COUNT:
            break
    return cleaned


def trim_trailing_low_confidence(
    words: list[dict[str, Any]], cutoff: float
) -> tuple[list[dict[str, Any]], list[str]]:
    """Cut the trailing run of low-confidence words (road noise, passenger talk).

    Never returns an empty list: if *every* word is below the cutoff the audio
    was bad as a whole, which is what ``TranscriptionResult.is_valid()`` already
    judges via ``avg_logprob`` — stripping it here would hide that signal behind
    a generic "empty transcription".
    """
    if not words:
        return [], []

    end = len(words)
    while end > 1 and float(words[end - 1].get("logprob", 0.0) or 0.0) < cutoff:
        end -= 1

    if end == 1 and float(words[0].get("logprob", 0.0) or 0.0) < cutoff:
        return words, []

    return words[:end], [str(w.get("text", "")) for w in words[end:]]


class ScribeBatchTranscriber:
    """Posts an audio clip to Scribe v2 batch and returns a TranscriptionResult."""

    def __init__(
        self,
        model: str = "scribe_v2",
        logprob_cutoff: float = -1.0,
        api_key: Optional[str] = None,
        trim_trailing: bool = False,
    ):
        self.model = model
        self.logprob_cutoff = logprob_cutoff
        self._api_key = api_key
        # #185 E: cutting is opt-in until the cutoff is calibrated — see
        # `Settings.stt_trim_trailing_low_confidence`.
        self.trim_trailing = trim_trailing

    @property
    def api_key(self) -> Optional[str]:
        # Read late, not at construction: services are wired up before tests and
        # env reloads mutate the environment (same reason as the TTS provider).
        return self._api_key or os.environ.get("ELEVENLABS_API_KEY")

    async def transcribe(
        self,
        audio_bytes: bytes,
        filename: str,
        language: Optional[str] = None,
        keyterms: Optional[list[str]] = None,
    ) -> TranscriptionResult:
        api_key = self.api_key
        if not api_key:
            raise ScribeUnavailable("ELEVENLABS_API_KEY is not set")

        # A dict, not a list of tuples: httpx only builds a multipart body from a
        # mapping (a list of pairs becomes a raw sync stream an AsyncClient
        # refuses to send). A list *value* is what encodes `keyterms` as the
        # repeated form field the API expects.
        data: dict[str, Any] = {
            "model_id": self.model,
            "timestamps_granularity": "word",
            "tag_audio_events": "false",
            "diarize": "false",
        }
        if language:
            data["language_code"] = language
        terms = sanitize_keyterms(keyterms)
        if terms:
            data["keyterms"] = terms

        try:
            async with httpx.AsyncClient(timeout=SCRIBE_TIMEOUT_SECONDS) as client:
                response = await client.post(
                    ELEVENLABS_STT_URL,
                    headers={"xi-api-key": api_key},
                    data=data,
                    files={"file": (filename, audio_bytes)},
                )
        except httpx.HTTPError as exc:
            raise ScribeUnavailable(f"ElevenLabs STT transport error: {exc}") from exc

        if response.status_code != 200:
            # Body is truncated and the key never logged: quota exhaustion
            # arrives here as a 401/402 body, which is why the fallback exists.
            raise ScribeUnavailable(
                f"ElevenLabs STT {response.status_code}: {response.text[:200]}"
            )

        return self._to_result(response.json())

    def _to_result(self, payload: dict[str, Any]) -> TranscriptionResult:
        raw_words = payload.get("words") or []
        # `spacing` carries no confidence and `audio_event` is not speech —
        # including either would drag the average logprob toward nonsense.
        words = [w for w in raw_words if w.get("type") == "word"]
        kept, stripped = trim_trailing_low_confidence(words, self.logprob_cutoff)

        text_words = kept
        if stripped and self.trim_trailing:
            logger.info(
                "Scribe trimmed %d trailing low-confidence word(s): %s",
                len(stripped),
                " ".join(stripped),
            )
        elif stripped:
            # Calibration data for the uncalibrated cutoff: what WOULD have been
            # cut, with every word's confidence, while the text keeps it all.
            text_words = words
            logger.info(
                "Scribe trailing low-confidence run kept (trim off, cutoff=%.2f): "
                "would have trimmed %d word(s) %r; word logprobs=%s",
                self.logprob_cutoff,
                len(stripped),
                " ".join(stripped),
                [
                    (
                        str(w.get("text", "")),
                        round(float(w.get("logprob", 0.0) or 0.0), 3),
                    )
                    for w in words
                ],
            )

        if kept:
            text = " ".join(str(w.get("text", "")) for w in text_words).strip()
            # Confidence stays measured on the answer run either way, so the
            # `is_valid` low-confidence gate behaves exactly as with trimming on.
            avg_logprob = fmean(float(w.get("logprob", 0.0) or 0.0) for w in kept)
        else:
            text = str(payload.get("text") or "").strip()
            avg_logprob = 0.0

        return TranscriptionResult(
            text=text,
            language=payload.get("language_code"),
            no_speech_prob=0.0 if kept else 1.0,
            avg_logprob=avg_logprob,
            duration=float(payload.get("audio_duration_secs") or 0.0),
        )
