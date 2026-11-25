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
    ... --key answer       # one prompt
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
    # The second silence (#243.4, founder 2026-11-24): the offer names the
    # exact command words, the long line the first times a player hears it
    # (iOS counts), the short one after.
    "no-answer-offer": {
        "sk": "Nepočujem odpoveď. Povedz: zopakuj, a prečítam otázku. Povedz: znova, a môžeš odpovedať. Alebo povedz: ďalšia.",
        "cs": "Neslyším odpověď. Řekni: zopakuj, a přečtu otázku. Řekni: znovu, a můžeš odpovědět. Nebo řekni: další.",
        "en": "I can't hear an answer. Say: repeat, and I'll read the question. Say: again, and you can answer. Or say: next.",
        "uk": "Не чую відповіді. Скажи: повтори, і я прочитаю питання. Скажи: ще раз, і зможеш відповісти. Або скажи: пропусти.",
    },
    "no-answer-offer-short": {
        "sk": "Nepočujem odpoveď. Povedz: zopakuj. Znova. Alebo ďalšia.",
        "cs": "Neslyším odpověď. Řekni: zopakuj. Znovu. Nebo další.",
        "en": "I can't hear an answer. Say: repeat. Again. Or next.",
        "uk": "Не чую відповіді. Скажи: повтори. Ще раз. Або пропусти.",
    },
    "say-next": {
        "sk": "Povedz: ďalšia.",
        "cs": "Řekni: další.",
        "en": "Say: next.",
        "uk": "Скажи: пропусти.",
    },
}


MAX_TAKES = 8

# Founder 2026-11-24 picked these by ear: the think lines calmer and steadier
# (B), the answer line a little slower (C). Flash, language code as in the app.
# Ukrainian keeps the app's v3 settings (no native ear yet).
CALM = {"speed": 1.0, "stability": 0.85, "similarity_boost": 0.75}
SLOWER = {"speed": 0.95, "stability": 0.6, "similarity_boost": 0.8}
VOICE_SETTINGS = {
    "think": CALM,
    "think-5": CALM,
    "think-10": CALM,
    "think-20": CALM,
    "think-30": CALM,
    "think-more": CALM,
    "no-answer-offer": CALM,
    "no-answer-offer-short": CALM,
    "answer": SLOWER,
    "say-next": CALM,
}


def _words(text: str) -> str:
    return re.sub(r"[^\w]+", " ", unicodedata.normalize("NFC", text.lower())).strip()


async def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", help="one language (sk, cs, en, uk)")
    parser.add_argument("--key", help="one prompt key (e.g. no-answer-offer)")
    parser.add_argument("--force", action="store_true")
    parser.add_argument(
        "--keep-unverified",
        action="store_true",
        help="keep the last take when none reads back exactly (only after a human listened)",
    )
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
            if args.key and key != args.key:
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
            settings = VOICE_SETTINGS.get(key) if language != "uk" else None
            base_payload = service.provider.payload_for

            def payload_for(text, style=None, settings=settings, base=base_payload):
                payload = base(text, style)
                if settings:
                    payload["voice_settings"] = dict(settings)
                return payload

            service.provider.payload_for = payload_for
            kept = None
            audio = None
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
            service.provider.payload_for = base_payload
            if kept is None and args.keep_unverified and audio is not None:
                print(f"! {path.name}: kept the last take unverified")
                kept = audio
            if kept is None:
                print(f"✗ {path.name}: no take read back as {text!r}")
                failures += 1
                continue
            path.write_bytes(kept)
            print(f"✓ {path.name} ({len(kept)} bytes)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
