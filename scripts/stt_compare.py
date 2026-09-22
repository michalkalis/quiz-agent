#!/usr/bin/env python3
"""#184 track B — offline STT comparison over the car samples.

Feeds every ``<stamp>.wav`` exported from the app (Settings → voice diagnostics →
Export recordings) to the backend's transcription providers and scores each
against a hand transcript, so the "batch beats realtime" claim of the issue's
done-state is a number, not a feeling.

Layout of the sample folder (as exported by the app + one file you add):
    20260922-101500-123.wav       the recording (16 kHz mono PCM)
    20260922-101500-123.json      sidecar: language, inputPort, voiceProcessing,
                                  durationMs, transcript (what prod heard)
    20260922-101500-123.ref.txt   YOUR hand transcript (one line) — optional;
                                  files without it are transcribed but not scored

Usage (repo root, backend env with ELEVENLABS_API_KEY / OPENAI_API_KEY set):
    uv run --no-sync python scripts/stt_compare.py ~/Downloads/AnswerRecordings \
        [--providers scribe,gpt-transcribe,whisper-1] [--csv out.csv]

Azure MAI-Transcribe-2 (the research's A/B challenger) is NOT wired here — no
Azure key/SDK in this repo yet; add a provider function when there is one. The
realtime path cannot be replayed from a file without re-implementing the
WebSocket client; the sidecar's ``transcript`` column IS the realtime/prod
result for samples recorded with the realtime switch on.
"""

from __future__ import annotations

import argparse
import asyncio
import csv
import io
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "packages" / "shared"))
sys.path.insert(0, str(ROOT / "apps" / "quiz-agent"))

from dotenv import load_dotenv

load_dotenv(ROOT / ".env")

from app.voice.scribe import ScribeBatchTranscriber
from app.voice.transcriber import VoiceTranscriber


def normalize(text: str) -> list[str]:
    text = text.lower()
    text = re.sub(r"[^\w\s]", " ", text, flags=re.UNICODE)
    return text.split()


def wer(reference: str, hypothesis: str) -> float:
    """Word error rate = Levenshtein distance over reference words / |reference|."""
    ref, hyp = normalize(reference), normalize(hypothesis)
    if not ref:
        return 0.0 if not hyp else 1.0
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        cur = [i] + [0] * len(hyp)
        for j, h in enumerate(hyp, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r != h))
        prev = cur
    return prev[-1] / len(ref)


async def run_provider(
    provider: str, wav: bytes, name: str, language: str | None
) -> str:
    if provider == "scribe":
        result = await ScribeBatchTranscriber().transcribe(
            wav, name, language=language, keyterms=[]
        )
        return result.text
    transcriber = VoiceTranscriber(model=provider)
    result = await transcriber._transcribe_openai(
        io.BytesIO(wav), name, prompt=None, language=language
    )
    return result.text


async def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("folder", type=Path)
    parser.add_argument("--providers", default="scribe,gpt-transcribe")
    parser.add_argument("--csv", type=Path, default=None)
    args = parser.parse_args()

    providers = [p.strip() for p in args.providers.split(",") if p.strip()]
    wavs = sorted(args.folder.glob("*.wav"))
    if not wavs:
        print(f"no .wav files in {args.folder}", file=sys.stderr)
        return 1

    rows: list[dict[str, str]] = []
    totals: dict[str, list[float]] = {p: [] for p in providers + ["prod"]}

    for wav_path in wavs:
        stamp = wav_path.stem
        sidecar = {}
        sidecar_path = wav_path.with_suffix(".json")
        if sidecar_path.exists():
            sidecar = json.loads(sidecar_path.read_text())
        ref_path = args.folder / f"{stamp}.ref.txt"
        reference = ref_path.read_text().strip() if ref_path.exists() else None
        language = sidecar.get("language")
        wav = wav_path.read_bytes()

        row = {
            "stamp": stamp,
            "language": language or "",
            "inputPort": sidecar.get("inputPort", ""),
            "voiceProcessing": str(sidecar.get("voiceProcessing", "")),
            "durationMs": str(sidecar.get("durationMs", "")),
            "reference": reference or "",
            "prod": sidecar.get("transcript") or "",
        }
        if reference and row["prod"]:
            score = wer(reference, row["prod"])
            row["prod_wer"] = f"{score:.2f}"
            totals["prod"].append(score)

        for provider in providers:
            try:
                text = await run_provider(provider, wav, wav_path.name, language)
            except Exception as exc:  # noqa: BLE001 — a provider outage must not stop the sweep
                text = f"<error: {exc}>"
            row[provider] = text
            if reference and not text.startswith("<error"):
                score = wer(reference, text)
                row[f"{provider}_wer"] = f"{score:.2f}"
                totals[provider].append(score)
        rows.append(row)
        print(f"{stamp}  ref={reference!r}")
        for key in ["prod", *providers]:
            print(
                f"    {key:>14}: {row.get(key, '')!r}  WER={row.get(f'{key}_wer', '-')}"
            )

    print("\n== mean WER over scored samples ==")
    for key, scores in totals.items():
        if scores:
            print(f"{key:>14}: {sum(scores) / len(scores):.3f}  (n={len(scores)})")
        else:
            print(f"{key:>14}: no scored samples (add <stamp>.ref.txt files)")

    if args.csv:
        fieldnames = sorted({k for r in rows for k in r})
        with args.csv.open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(rows)
        print(f"\nwrote {args.csv}")
    return 0


if __name__ == "__main__":
    if not os.environ.get("ELEVENLABS_API_KEY"):
        print(
            "warning: ELEVENLABS_API_KEY not set — scribe will report an error per file",
            file=sys.stderr,
        )
    raise SystemExit(asyncio.run(main()))
