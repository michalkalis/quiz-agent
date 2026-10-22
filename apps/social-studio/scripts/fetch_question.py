"""READ-ONLY: one approved question + its existing app voice clip, from prod.

Not run locally: the CLI pipes this file into the prod API machine
(`fly ssh console -a quiz-agent-api -C "python - <id> <lang>"`), where the app
code, DB URL and R2 credentials already live, so no secret ever leaves Fly.

- SELECT only, inside a READ ONLY transaction; R2 GET only.
- Never synthesizes: the clip is looked up under the exact cache key the app
  uses (TTSCache hash of spoken text + voice). No clip -> "audio_b64": null and
  the reel renders without voice.

Usage: python - <question-id> [en|sk|cs]   (prints "@@JSON@@{...}")
       python - --coverage                 (clip counts per language)
"""

import asyncio
import base64
import json
import os
import sys
from types import SimpleNamespace

sys.path.insert(0, "/app")

import asyncpg
import boto3
from app.tts.cache import TTSCache
from app.tts.number_normalization import normalize_numbers_for_tts
from app.tts.spoken_text import spoken_question_text
from app.tts.voices import ELEVENLABS_VOICES, VOICE_PROFILES
from botocore.config import Config

# Every voice the app has used; the active one (TTS_VOICE or George) first.
VOICES = list(ELEVENLABS_VOICES.values()) + list(VOICE_PROFILES.values())
if os.environ.get("TTS_VOICE"):
    VOICES.insert(0, os.environ["TTS_VOICE"])


def _json(v):
    return json.loads(v) if isinstance(v, str) else v


def spoken_candidates(text, options, lang):
    """The texts the app may have read: stem, or stem + options in both label
    styles (old clients hear keys, `option-labels` clients hear labels)."""
    caps = [()] + ([("option-labels",)] if options else [])
    for c in caps:
        session = SimpleNamespace(client_capabilities=c, language=lang)
        yield normalize_numbers_for_tts(spoken_question_text(text, options, session), lang)


def clip_keys(text, options, lang):
    for spoken in spoken_candidates(text, options, lang):
        for voice in VOICES:
            yield spoken, f"questions/{TTSCache._hash(None, spoken, voice)}.opus"


def s3_client():
    return boto3.client(
        "s3",
        endpoint_url=os.environ["TTS_R2_ENDPOINT"],
        aws_access_key_id=os.environ["TTS_R2_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["TTS_R2_SECRET_ACCESS_KEY"],
        config=Config(signature_version="s3v4", retries={"max_attempts": 2}),
        region_name="auto",
    )


async def fetch_rows(sql, *args):
    url = os.environ["DATABASE_URL"].replace("postgresql+asyncpg://", "postgresql://")
    conn = await asyncpg.connect(url)
    try:
        async with conn.transaction(readonly=True):
            return await conn.fetch(sql, *args)
    finally:
        await conn.close()


async def one(qid, lang):
    rows = await fetch_rows(
        "select id::text, question, possible_answers, correct_answer, headline_answer, "
        "explanation, category, coalesce(language, 'en') as language from questions "
        "where id = $1::uuid and review_status = 'approved'",
        qid,
    )
    if not rows:
        return {"error": f"{qid}: not found or not approved"}
    r = dict(rows[0])
    out = {
        "id": r["id"],
        "category": r["category"],
        "language": r["language"],
        "question": r["question"],
        "possible_answers": _json(r["possible_answers"]),
        "correct_answer": _json(r["correct_answer"]),
        "headline_answer": r["headline_answer"],
        "explanation": r["explanation"],
    }
    lang = lang or out["language"]
    if lang != out["language"]:
        tr = await fetch_rows(
            "select question, possible_answers, correct_answer, correct_answer_key, "
            "headline_answer, explanation from question_translations "
            "where question_id = $1::uuid and language = $2 and status = 'approved'",
            qid,
            lang,
        )
        if not tr:
            return {"error": f"{qid}: no approved {lang} translation"}
        t = dict(tr[0])
        out.update(
            language=lang,
            question=t["question"],
            possible_answers=_json(t["possible_answers"]),
            correct_answer=t["correct_answer"],
            correct_answer_key=t["correct_answer_key"],
            headline_answer=t["headline_answer"],
            explanation=t["explanation"],
        )
    s3, bucket = s3_client(), os.environ["TTS_R2_BUCKET"]
    out["audio_b64"] = None
    for spoken, key in clip_keys(out["question"], out["possible_answers"], lang):
        try:
            body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        except s3.exceptions.NoSuchKey:
            continue
        out.update(audio_b64=base64.b64encode(body).decode(), spoken_text=spoken)
        break
    return out


async def coverage():
    qs = await fetch_rows(
        "select id::text, question, possible_answers, coalesce(language, 'en') as language "
        "from questions where review_status = 'approved'"
    )
    trs = await fetch_rows(
        "select t.question_id::text as id, t.question, t.possible_answers, t.language "
        "from question_translations t join questions q on q.id = t.question_id "
        "where q.review_status = 'approved' and t.status = 'approved'"
    )
    s3, bucket = s3_client(), os.environ["TTS_R2_BUCKET"]
    keys = set()
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix="questions/"):
        keys.update(o["Key"] for o in page.get("Contents", []))
    stats = {}
    for r in list(qs) + list(trs):
        st = stats.setdefault(r["language"], {"questions": 0, "with_clip": 0})
        st["questions"] += 1
        opts = _json(r["possible_answers"])
        if any(k in keys for _, k in clip_keys(r["question"], opts, r["language"])):
            st["with_clip"] += 1
    return {"r2_question_clips": len(keys), "per_language": stats}


if __name__ == "__main__":
    if sys.argv[1] == "--coverage":
        result = asyncio.run(coverage())
    else:
        result = asyncio.run(one(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None))
    print("@@JSON@@" + json.dumps(result, ensure_ascii=False, default=str))
