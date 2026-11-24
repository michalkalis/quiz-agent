#!/usr/bin/env python3
"""Generate the bundled phase prompts in the app voice (#243.3).

Founder 2026-11-24: "Premýšľaj." / "Odpovedaj." and the other short phase
lines play from the app bundle, so they sound at once and without signal, in
the same ElevenLabs voice, model and speed the backend uses for every other
spoken line (`TTSService` with the quiz language's style). Never the iOS
system voice.

The texts live in `PHASE_PROMPTS` below and MUST match
`apps/ios-app/Hangs/Hangs/Utilities/PhasePrompt.swift` (a unit test there
checks that every case has a bundled file per language).

Two short lines still read back unsure (sk "Odpovedaj." as Polish, uk
"Подумай ще." as Bulgarian in Whisper's language guess) and wait for the
founder's ear on device (#243.3).

Usage (repo root; reads the ElevenLabs key from the root .env like the app):
    cd apps/quiz-agent && uv run --no-sync python ../../scripts/generate_phase_prompts.py
    ... --only sk          # one language
    ... --force            # regenerate files that already exist
"""

import argparse
import asyncio
import os
import re
import sys
import unicodedata
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_DIR = REPO_ROOT / "apps/ios-app/Hangs/Hangs/Resources/PhasePrompts"

# key -> language -> text. Keys are `PhasePrompt.resourceName` on iOS.
PHASE_PROMPTS: dict[str, dict[str, str]] = {
    "think": {
        "sk": "Premýšľaj.",
        "cs": "Přemýšlej.",
        "en": "Think.",
        "uk": "Подумай.",
    },
    "think-5": {
        "sk": "Premýšľaj, máš päť sekúnd.",
        "cs": "Přemýšlej, máš pět sekund.",
        "en": "Think, you have five seconds.",
        "uk": "Подумай, маєш п'ять секунд.",
    },
    "think-10": {
        "sk": "Premýšľaj, máš desať sekúnd.",
        "cs": "Přemýšlej, máš deset sekund.",
        "en": "Think, you have ten seconds.",
        "uk": "Подумай, маєш десять секунд.",
    },
    "think-20": {
        "sk": "Premýšľaj, máš dvadsať sekúnd.",
        "cs": "Přemýšlej, máš dvacet sekund.",
        "en": "Think, you have twenty seconds.",
        "uk": "Подумай, маєш двадцять секунд.",
    },
    "think-30": {
        "sk": "Premýšľaj, máš tridsať sekúnd.",
        "cs": "Přemýšlej, máš třicet sekund.",
        "en": "Think, you have thirty seconds.",
        "uk": "Подумай, маєш тридцять секунд.",
    },
    "think-more": {
        "sk": "Premýšľaj ešte.",
        "cs": "Přemýšlej ještě.",
        "en": "Keep thinking.",
        "uk": "Подумай ще.",
    },
    "answer": {
        "sk": "Odpovedaj.",
        "cs": "Odpovídej.",
        "en": "Answer.",
        "uk": "Відповідай.",
    },
    "no-answer-offer": {
        "sk": "Zopakovať otázku, znova, alebo ďalšia?",
        "cs": "Zopakovat otázku, znovu, nebo další?",
        "en": "Repeat the question, again, or next?",
        "uk": "Повторити питання, знову чи наступне?",
    },
}


MAX_TAKES = 8


def _words(text: str) -> str:
    return re.sub(r"[^\w]+", " ", unicodedata.normalize("NFC", text.lower())).strip()


async def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", help="one language (sk, cs, en, uk)")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    from dotenv import load_dotenv

    load_dotenv(REPO_ROOT / ".env")
    sys.path.insert(0, str(REPO_ROOT / "apps/quiz-agent"))
    from app.tts.service import TTSService
    from quiz_shared.llm import factory

    stt = factory.openai_client(direct=True)

    service = TTSService(
        cache_dir=os.environ.get("TMPDIR", "/tmp") + "/phase-prompt-cache"
    )
    if service.provider.name != "elevenlabs":
        print(f"✗ primary TTS is {service.provider.name}, not ElevenLabs")
        return 1
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    failures = 0
    for key, texts in PHASE_PROMPTS.items():
        for language, text in texts.items():
            if args.only and language != args.only:
                continue
            path = OUTPUT_DIR / f"{key}.{language}.mp3"
            if path.exists() and not args.force:
                continue
            # The primary only, never the failover: the backup voice must not
            # ship in the bundle. A bare word can come out in the wrong
            # language (memory: TTS sk/cs pronunciation), so each take is
            # transcribed with the language given and the first that reads
            # back exactly is kept. Never checked by playing it out loud.
            style = service.style_for(language)
            kept = None
            for take in range(MAX_TAKES):
                try:
                    audio = await service._synthesize_with(
                        service.provider,
                        text,
                        service._primary_voice(style),
                        False,
                        style=style,
                    )
                except Exception as error:  # noqa: BLE001 — report every miss, then fail
                    print(f"✗ {path.name}: {error}")
                    break
                heard = stt.audio.transcriptions.create(
                    model="gpt-4o-transcribe",
                    file=("take.mp3", audio),
                    language=language,
                ).text
                print(f"  {path.name} take {take + 1}: heard {heard!r}")
                if _words(heard) == _words(text):
                    kept = audio
                    break
            if kept is None:
                print(f"✗ {path.name}: no take read back as {text!r}")
                failures += 1
                continue
            path.write_bytes(kept)
            print(f"✓ {path.name} ({len(kept)} bytes)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
