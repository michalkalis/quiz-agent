#!/usr/bin/env python3
"""Pre-read approved corpus questions into the shared TTS cache.

Players otherwise wait for the first reading of every question. This builds
the exact text the serve route synthesizes (stored translation → spoken text
with MCQ option labels → numbers spelled out), so each warmed clip is a cache
key a real session reads. Already cached clips cost nothing.

Run inside the quiz-agent container (it needs DATABASE_URL, the TTS keys and
the R2 cache env):

    python scripts/warm_question_tts.py --per-language 200 [--dry-run]

Boosted (fresh) questions go first, the rest are random.
"""

import argparse
import asyncio
import os
import sys
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


async def tts_texts(store: PgvectorQuestionStore, lang: str, n: int) -> list[str]:
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
    return texts


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--per-language", type=int, default=200)
    parser.add_argument("--languages", default="en,sk,cs")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    store = PgvectorQuestionStore(database_url=get_settings().database_url)
    tts = None if args.dry_run else TTSService()
    for lang in args.languages.split(","):
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
                await tts.synthesize_question(t)
            except Exception as exc:  # noqa: BLE001  one bad clip must not stop the batch
                failed += 1
                print(f"  failed: {exc}", flush=True)
            if i % 50 == 0:
                print(f"  {lang}: {i}/{len(texts)}", flush=True)
        print(f"{lang}: done, {failed} failed", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
