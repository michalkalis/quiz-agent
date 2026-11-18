#!/usr/bin/env python3
"""Pre-read approved corpus questions into the shared TTS cache.

Players otherwise wait for the first reading of every question. This builds
the exact text the serve route synthesizes (stored translation → spoken text
with MCQ option labels → numbers spelled out), so each warmed clip is a cache
key a real session reads. Already cached clips cost nothing.

Run inside the quiz-agent container (it needs DATABASE_URL, the TTS keys and
the R2 cache env):

    python scripts/warm_question_tts.py --per-language 200 [--dry-run]
    python scripts/warm_question_tts.py --rerecord [--languages en,sk,cs] [--dry-run]

Boosted (fresh) questions go first, the rest are random.

--rerecord (faster voice, founder 2026-11-18): every live question and
"hear it" explanation whose clip players already heard (the R2 key from before
`TTS_LANGUAGE_STYLES`) is read again in the language's current style; the old
clip stays in R2 for a rollback. ElevenLabs only (never a fallback-voice clip),
resumable (a clip already in the new style is skipped), and its spend is left
out of the players' daily budget as it goes, so the run never puts them on the
fallback voice.
"""

import argparse
import asyncio
import os
import sys
import tempfile
from types import SimpleNamespace

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.client_capabilities import ANSWER_CODES, OPTION_LABELS
from app.config import get_settings
from app.serializers import translated_question_payload
from app.tts.number_normalization import normalize_numbers_for_tts
from app.tts.service import TTSService
from app.tts.spoken_text import spoken_question_text
from quiz_shared.database.pgvector_client import PgvectorQuestionStore
from sqlalchemy import text

LIVE = "q.pack_id IS NULL AND q.review_status = 'approved'"
ORDER = "(q.boost_until IS NOT NULL AND q.boost_until > now()) DESC, random()"
# --rerecord: settle the batch's spend with the daily budget this often.
SETTLE_EVERY = 20

# English pool: English rows. Other languages: native rows plus English rows
# with an approved stored translation (what an anonymous client is served).
SQL_EN = f"""
SELECT q.id FROM questions q
WHERE {LIVE} AND coalesce(q.language, 'en') = 'en'
ORDER BY {ORDER} LIMIT :n
"""
SQL_OTHER = f"""
SELECT q.id FROM questions q
WHERE {LIVE} AND (
  q.language = :lang
  OR (coalesce(q.language, 'en') = 'en' AND NOT q.language_dependent AND EXISTS (
    SELECT 1 FROM question_translations t
    WHERE t.question_id = q.id AND t.language = :lang AND t.status = 'approved'))
)
ORDER BY {ORDER} LIMIT :n
"""


async def tts_texts(
    store: PgvectorQuestionStore, lang: str, n: int, explanations: bool = False
) -> list[str]:
    async with store._session_factory() as db:
        sql = SQL_EN if lang == "en" else SQL_OTHER
        ids = [str(r[0]) for r in (await db.execute(text(sql), {"lang": lang, "n": n}))]
    # Current builds declare these, so MCQ options are read with their labels.
    session = SimpleNamespace(
        language=lang, client_capabilities=[ANSWER_CODES, OPTION_LABELS]
    )
    texts = []
    for qid in ids:
        question = await store.get(qid)
        if question is None:
            continue
        payload, _ = await translated_question_payload(
            question, lang, None, question_store=store
        )
        spoken = spoken_question_text(
            payload["question"], payload.get("possible_answers"), session
        )
        texts.append(normalize_numbers_for_tts(spoken, lang))
        # The app's "hear it" button sends the bare explanation with the quiz
        # language to POST /tts/synthesize, which spells digits out the same way.
        if explanations and payload.get("explanation"):
            texts.append(normalize_numbers_for_tts(payload["explanation"], lang))
    return texts


def r2_keys(remote) -> set[str]:
    keys = set()
    pages = remote._client.get_paginator("list_objects_v2").paginate(
        Bucket=remote._bucket, Prefix="questions/"
    )
    for page in pages:
        keys.update(o["Key"] for o in page.get("Contents", []))
    return keys


async def rerecord(store, langs: list[str], dry_run: bool) -> None:
    from app.db.engine import get_sessionmaker
    from app.usage.elevenlabs_budget import exclude_from_today, fetch_credits_used

    with tempfile.TemporaryDirectory() as tmp:
        # Own L1: the app's cache metadata is not shared with a second process.
        tts = TTSService(cache_dir=tmp)
        tts.fallback = None  # George or nothing; a miss is made on demand later
        if tts.provider.name != "elevenlabs" or tts.remote is None:
            sys.exit("needs ElevenLabs as the primary voice and the R2 cache env")
        voice = tts.provider.default_voice
        keys = r2_keys(tts.remote)
        print(f"R2: {len(keys)} question clips", flush=True)

        sessionmaker = get_sessionmaker()
        start = mark = await fetch_credits_used()

        async def settle() -> None:
            nonlocal mark
            used = await fetch_credits_used()
            if used > mark:
                await exclude_from_today(sessionmaker, used - mark, used)
                mark = used

        for lang in langs:
            texts = await tts_texts(store, lang, 1_000_000, explanations=True)
            todo = list(
                dict.fromkeys(
                    t
                    for t in texts
                    if tts._remote_key(t, voice) in keys
                    and tts.remote_key_for(t, lang) not in keys
                )
            )
            chars = sum(len(t) for t in todo)
            print(f"{lang}: {len(todo)} clips to re-record, {chars} chars", flush=True)
            if dry_run:
                continue
            failed = 0
            for i, t in enumerate(todo, 1):
                try:
                    await tts.synthesize(t, use_cache=True, language=lang)
                except Exception as exc:  # noqa: BLE001  one bad clip must not stop the batch
                    failed += 1
                    print(f"  failed: {exc}", flush=True)
                if i % SETTLE_EVERY == 0:
                    await settle()
                if i % 100 == 0:
                    print(f"  {lang}: {i}/{len(todo)}", flush=True)
            await settle()
            print(
                f"{lang}: done, {len(todo) - failed} recorded, {failed} failed",
                flush=True,
            )

        # ElevenLabs' meter lags a little: settle once more after it catches up.
        await asyncio.sleep(90)
        await settle()
        print(f"credits spent: {mark - start}", flush=True)


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--per-language", type=int, default=200)
    parser.add_argument("--languages", default="en,sk,cs")
    parser.add_argument("--rerecord", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    store = PgvectorQuestionStore(database_url=get_settings().database_url)
    langs = args.languages.split(",")
    if args.rerecord:
        await rerecord(store, langs, args.dry_run)
        return
    tts = None if args.dry_run else TTSService()
    for lang in langs:
        texts = await tts_texts(store, lang, args.per_language)
        chars = sum(len(t) for t in texts)
        print(f"{lang}: {len(texts)} questions, {chars} characters", flush=True)
        if tts is None:
            for t in texts[:3]:
                print(f"  {t}")
            continue
        failed = 0
        for i, t in enumerate(texts, 1):
            try:
                await tts.synthesize_question(t, language=lang)
            except Exception as exc:  # noqa: BLE001  one bad clip must not stop the batch
                failed += 1
                print(f"  failed: {exc}", flush=True)
            if i % 50 == 0:
                print(f"  {lang}: {i}/{len(texts)}", flush=True)
        print(f"{lang}: done, {failed} failed", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
