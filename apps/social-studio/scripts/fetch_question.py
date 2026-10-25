"""One approved question + its app voice clip, from prod.

Not run locally: the CLI pipes this file into the prod API machine
(`fly ssh console -a quiz-agent-api -C "python - <id> <lang>"`), where the app
code, DB URL and R2 credentials already live, so no secret ever leaves Fly.

- SELECT only, inside a READ ONLY transaction; R2 GET only.
- The clip is looked up under the exact cache key the app uses (TTSCache hash
  of spoken text + voice). No clip -> "audio_b64": null and the reel renders
  without voice. Same for the explanation: the app reads the bare explanation
  ("hear it" on the result screen), so its clip is shared the same way.
- The one write, only with --ensure-audio and only for a missing clip:
  the app's own TTSService speaks the text the app would read (shipped client
  capabilities) in the app voice and stores it in R2 under the app's key, so a
  player who later gets the question hears this same clip (founder 2026-10-22).
  ElevenLabs only (no fallback voice); refused past the app's daily budget.

Usage: python - <question-id> [en|sk|cs] [--ensure-audio [--question-only]]   (prints "@@JSON@@{...}")
       python - --coverage                                   (clip counts per language)
       python - --candidates                                 (weekly batch pool, cli/batch.ts)
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
from app.client_capabilities import ANSWER_CODES, OPTION_LABELS
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
        yield normalize_numbers_for_tts(
            spoken_question_text(text, options, session), lang
        )


def clip_keys(text, options, lang):
    for spoken in spoken_candidates(text, options, lang):
        for voice in VOICES:
            yield spoken, f"questions/{TTSCache._hash(None, spoken, voice)}.opus"


def explanation_keys(explanation, lang):
    """The app's "hear it" clip: the bare explanation (iOS splits only past
    1000 characters, which no approved explanation reaches)."""
    spoken = normalize_numbers_for_tts(explanation or "", lang)
    for voice in VOICES:
        yield spoken, f"questions/{TTSCache._hash(None, spoken, voice)}.opus"


def first_clip(s3, bucket, keys):
    for spoken, key in keys:
        try:
            return spoken, s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        except s3.exceptions.NoSuchKey:
            continue
    return None, None


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
        "explanation, category, coalesce(language, 'en') as language, source_url from questions "
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
        "source_url": r["source_url"],
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
    out["audio_b64"] = out["explanation_audio_b64"] = None
    spoken, body = first_clip(
        s3, bucket, clip_keys(out["question"], out["possible_answers"], lang)
    )
    if body:
        out.update(audio_b64=base64.b64encode(body).decode(), spoken_text=spoken)
    if out["explanation"] and len(out["explanation"]) <= 1000:
        spoken, body = first_clip(
            s3, bucket, explanation_keys(out["explanation"], lang)
        )
        if body:
            out.update(
                explanation_audio_b64=base64.b64encode(body).decode(),
                explanation_spoken=spoken,
            )
    return out


# What the shipped apps (1.0 beta and 1.1) send as X-Client-Capabilities.
APP_CAPABILITIES = (ANSWER_CODES, OPTION_LABELS)


async def elevenlabs_usage():
    """(credits used this billing period, period limit): read-only GET."""
    import httpx
    from app.usage.elevenlabs_budget import SUBSCRIPTION_URL

    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.get(
            SUBSCRIPTION_URL, headers={"xi-api-key": os.environ["ELEVENLABS_API_KEY"]}
        )
        resp.raise_for_status()
        sub = resp.json()
        return int(sub["character_count"]), int(sub["character_limit"])


async def ensure(qid, lang, question_only=False):
    """`one`, plus clips made through the app's own TTS path for what is
    missing: the question as the app reads it, and the explanation as the
    app's "hear it" button reads it."""
    import tempfile

    from app.config import get_settings
    from app.tts.service import TTSBilling, TTSService

    out = await one(qid, lang)
    if out.get("error"):
        return out
    todo = []  # (what, audio field, text field, spoken); an existing clip is never paid for twice
    if not out["audio_b64"]:
        session = SimpleNamespace(
            client_capabilities=APP_CAPABILITIES, language=out["language"]
        )
        # Same text GET /sessions/{id}/question/audio builds for such a session.
        spoken = normalize_numbers_for_tts(
            spoken_question_text(out["question"], out["possible_answers"], session),
            out["language"],
        )
        todo.append(("question", "audio_b64", "spoken_text", spoken))
    if (
        not question_only
        and out["explanation"]
        and not out["explanation_audio_b64"]
        and len(out["explanation"]) <= 1000
    ):
        spoken = normalize_numbers_for_tts(out["explanation"], out["language"])
        todo.append(
            ("explanation", "explanation_audio_b64", "explanation_spoken", spoken)
        )
    if not todo:
        return out
    chars = sum(len(t[3]) for t in todo)
    used, limit = await elevenlabs_usage()
    # The app's own service-wide gate (#207.13): today's spend from the
    # day-start reading the app stored. Never eat into what players need.
    start = await fetch_rows(
        "select amount from usage_counters where subject_id = '__service__' "
        "and usage_date = current_date and metric = 'elevenlabs_credits_at_day_start'"
    )
    day_start = start[0]["amount"] if start else used
    spent_today = used - day_start if used >= day_start else used
    budget = get_settings().elevenlabs_daily_credit_budget
    if budget and spent_today + chars > budget:
        return {
            "error": f"{qid}: ElevenLabs daily budget would be passed "
            f"({spent_today} + {chars} > {budget})"
        }
    if limit - used < chars:
        return {"error": f"{qid}: not enough ElevenLabs credits ({limit - used} left)"}
    clips = []
    # Temp L1 dir: the machine's own cache belongs to the app user; R2 (L2)
    # is the shared store every machine reads on a miss.
    with tempfile.TemporaryDirectory() as tmp:
        tts = TTSService(cache_dir=tmp)
        tts.fallback = None  # the app voice or nothing, never a fallback-voice clip
        if tts.provider.name != "elevenlabs" or tts.remote is None:
            return {"error": "app TTS is not ElevenLabs + R2 on this machine"}
        voice = tts.provider.default_voice
        for what, audio_field, text_field, spoken in todo:
            billing = TTSBilling()
            audio = await tts.synthesize(text=spoken, use_cache=True, billing=billing)
            key = tts._remote_key(spoken, voice)
            if await tts.remote.get(key) is None:
                return {
                    "error": f"{qid}: {what} clip made but not found in R2 under {key}"
                }
            out.update(
                {audio_field: base64.b64encode(audio).decode(), text_field: spoken}
            )
            clips.append({"what": what, "chars": billing.billed_chars, "r2_key": key})
    out["generated"] = {
        "clips": clips,
        "chars": sum(c["chars"] for c in clips),
        # ElevenLabs' usage counter lags; this is the reading before.
        "credits_left_before": limit - used,
        "voice": voice,
    }
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
    for page in s3.get_paginator("list_objects_v2").paginate(
        Bucket=bucket, Prefix="questions/"
    ):
        keys.update(o["Key"] for o in page.get("Contents", []))
    stats = {}
    for r in list(qs) + list(trs):
        st = stats.setdefault(r["language"], {"questions": 0, "with_clip": 0})
        st["questions"] += 1
        opts = _json(r["possible_answers"])
        if any(k in keys for _, k in clip_keys(r["question"], opts, r["language"])):
            st["with_clip"] += 1
    return {"r2_question_clips": len(keys), "per_language": stats}


async def candidates():
    """Approved native rows for the weekly batch (#210 sub-task 210.4): human
    rating (founder/rater 0..1), topicality, local scope, and whether the app
    clip already exists. Read-only."""
    rows = await fetch_rows(
        "select q.id::text, coalesce(q.language, 'en') as language, q.category, "
        "q.question, q.possible_answers, q.local_scope, q.explanation, q.source_url, "
        "coalesce(q.headline_answer, q.correct_answer->>0, q.correct_answer#>>'{}') as answer, q.created_at::date::text as created, "
        "q.provenance->'extra'->'topicality'->>'tier' as topicality, "
        "(select avg(r.score / r.scale_max) from ratings r where r.question_id = q.id::text) as rating "
        "from questions q where q.review_status = 'approved' "
        "and (q.expires_at is null or q.expires_at > now() + interval '14 days')"
    )
    s3, bucket = s3_client(), os.environ["TTS_R2_BUCKET"]
    keys = set()
    for page in s3.get_paginator("list_objects_v2").paginate(
        Bucket=bucket, Prefix="questions/"
    ):
        keys.update(o["Key"] for o in page.get("Contents", []))
    out = []
    for r in rows:
        opts = _json(r["possible_answers"])
        out.append(
            {
                "id": r["id"],
                "language": r["language"],
                "category": r["category"],
                "chars": len(r["question"]),
                # Full text for the content review before a batch (210.4).
                "question": r["question"],
                "answer": r["answer"],
                "options": opts,
                "explanation": r["explanation"],
                "source_url": r["source_url"],
                "answer_chars": len(r["answer"] or ""),
                "mcq": bool(opts),
                "local_scope": r["local_scope"],
                "created": r["created"],
                "topicality": r["topicality"],
                "rating": float(r["rating"]) if r["rating"] is not None else None,
                "has_clip": any(
                    k in keys for _, k in clip_keys(r["question"], opts, r["language"])
                ),
            }
        )
    return out


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a not in ("--ensure-audio", "--question-only")]
    if args[0] == "--coverage":
        result = asyncio.run(coverage())
    elif args[0] == "--candidates":
        result = asyncio.run(candidates())
    else:
        lang = args[1] if len(args) > 1 else None
        if "--ensure-audio" in sys.argv:
            result = asyncio.run(ensure(args[0], lang, "--question-only" in sys.argv))
        else:
            result = asyncio.run(one(args[0], lang))
    print("@@JSON@@" + json.dumps(result, ensure_ascii=False, default=str))
