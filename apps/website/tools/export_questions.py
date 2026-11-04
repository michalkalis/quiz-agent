# Read-only export of servable sk/cs/en questions for the topic pages (#223). Runs on the quiz-agent-api machine inside a READ ONLY transaction; see tools/topic_snapshot.py.
import asyncio
import base64
import gzip
import json
import os

import asyncpg

url = os.environ["DATABASE_URL"].replace("postgresql+asyncpg://", "postgresql://").replace("postgres+asyncpg://", "postgresql://")
COMMON = "q.id::text, q.category, q.subtopic, q.topic, q.tags, q.difficulty, q.type, q.local_scope, q.age_appropriate, q.source_url, q.freshness_tag, q.expires_at::text"
SERVABLE = "q.review_status='approved' AND q.pack_id IS NULL AND (q.expires_at IS NULL OR q.expires_at > now()) AND q.embedding IS NOT NULL AND q.type IN ('text','text_multichoice')"
async def main():
  c = await asyncpg.connect(url)
  async with c.transaction(readonly=True):
    a = await c.fetch(f"SELECT COALESCE(q.language,'en'), q.question, q.correct_answer::text, q.alternative_answers::text, q.possible_answers::text, q.explanation, q.headline_answer, 'native', {COMMON} FROM questions q WHERE {SERVABLE} AND COALESCE(q.language,'en') IN ('sk','cs','en')")
    b = await c.fetch(f"SELECT t.language, t.question, t.correct_answer, t.alternative_answers::text, t.possible_answers::text, t.explanation, t.headline_answer, 'translation', {COMMON} FROM question_translations t JOIN questions q ON q.id=t.question_id WHERE {SERVABLE} AND t.status='approved' AND t.language IN ('sk','cs') AND (q.language IS NULL OR q.language='en') AND t.language = ANY(q.approved_languages)")
  await c.close()
  return [tuple(r) for r in a] + [tuple(r) for r in b]
out = asyncio.run(main())
cols = ["lang","question","answer","alternatives","options","explanation","headline","kind","id","category","subtopic","topic","tags","difficulty","type","local_scope","age","source_url","freshness","expires_at"]
rows = [dict(zip(cols, r)) for r in out]
print("COUNT", len(rows))
print("B64:" + base64.b64encode(gzip.compress(json.dumps(rows, ensure_ascii=False, default=str).encode())).decode())
