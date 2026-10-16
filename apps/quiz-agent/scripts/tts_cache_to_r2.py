"""One-off: copy the volume's TTS cache into the shared R2 bucket (#207.20).

Run on the prod machine before the volume goes away, so nothing already paid
for is bought again from ElevenLabs:

    fly ssh console -a quiz-agent-api -C "python -m scripts.tts_cache_to_r2 /data/tts_cache"

Keys match ``TTSService._remote_key`` / ``_remote_static_key``
(``questions/<hash>.opus``, ``static/<file>``). Objects already in the bucket
are skipped, so re-running is cheap. Prints counts only.
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

from app.tts.remote_cache import R2AudioStore


async def main(cache_dir: str) -> None:
    store = R2AudioStore.from_env()
    if store is None:
        sys.exit("TTS_R2_* env missing")
    root = Path(cache_dir)
    copied = skipped = 0
    for sub in ("questions", "static"):
        for path in sorted((root / sub).glob("*.opus")):
            key = f"{sub}/{path.name}"
            if await store.get(key):
                skipped += 1
                continue
            await store.put(key, path.read_bytes())
            copied += 1
    print(f"copied={copied} already_there={skipped}")


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1] if len(sys.argv) > 1 else "/data/tts_cache"))
