"""``verify`` gate outcomes → row status + the ``approved_languages`` index (T16).

Why it matters: ``approved_languages`` is what a Slovak session is served
from. It must flip ON only for an approved row, in the same transaction, and
OFF for everything else; an unavailable leg must leave the row pending
(retryable), never approved and never rejected. The LLM legs are stubbed —
this test is about the wiring, the judge/answerability bars have their own.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from typing import ClassVar

import pytest
from app.translation_verification.judge import Finding, JudgeResult
from app.translation_verification.regional import RegionalRelevance
from scripts.translation_runner import verify as ver
from scripts.translation_runner import workset as ws
from scripts.translation_runner.translate import ingest_job
from sqlalchemy import text

from tests.scripts.conftest import delete_questions, make_question

pytestmark = pytest.mark.asyncio


@dataclass
class _Ans:
    verdict: str
    model: str = "stub"

    def to_verification_json(self) -> dict:
        return {"verdict": self.verdict, "model": self.model}


class _Checker:
    verdicts: ClassVar[dict[str, str]] = {}

    def __init__(self, model=None):
        pass

    async def check(self, source, draft, language):
        return _Ans(self.verdicts.get(source.id, "pass"))


class _Judge:
    results: ClassVar[dict[str, JudgeResult]] = {}

    def __init__(self, model=None):
        pass

    async def judge(self, source_question, translated_draft, language):
        return self.results.get(translated_draft["question"], JudgeResult(verdict="ok"))


class _Regional:
    async def classify(self, question_text, language, possible_answers=None):
        return RegionalRelevance(flag=False, reason="stub")


def _job(
    tmp_path, entries: list[tuple[uuid.UUID, str, str]], job_id: str = "sk-verify"
) -> ws.Job:
    job = ws.Job(job_id, jobs_dir=tmp_path)
    for qid, translated, source_hash in entries:
        job.append(
            {
                "kind": "translation",
                "qid": str(qid),
                "language": "sk",
                "payload": {
                    "question": translated,
                    "possible_answers": None,
                    "correct_answer": "Taliansko",
                    "alternative_answers": ["Itália"],
                    "explanation": "Rosso corsa bola talianska farba.",
                    "headline_answer": None,
                },
                "model": "session:opus",
                "transport": "session",
                "prompt_version": "corpus-v1",
                "source_hash": source_hash,
                "correct_answer_key": None,
            }
        )
    job.append({"kind": "cost", "usd": 0.0, "n_requests": len(entries)})
    return job


async def test_verify_flips_approved_languages_only_for_approved(
    translation_engine, question_store, tmp_path, monkeypatch
) -> None:
    monkeypatch.setattr(ver, "DeltaAnswerabilityChecker", _Checker)
    monkeypatch.setattr(ver, "TranslationJudge", _Judge)
    monkeypatch.setattr(ver, "RegionalClassifier", _Regional)

    qids = {
        name: uuid.uuid4()
        for name in ("ok", "flip", "critical", "unavailable", "stale")
    }
    questions = {name: make_question(qid) for name, qid in qids.items()}
    for q in questions.values():
        assert await question_store.add(q) is True
    try:
        rows = await ws.fetch_source_rows(translation_engine, ["approved"])
        by_id = {r["id"]: r for r in rows}
        entries = []
        for name, qid in qids.items():
            h = ws.row_source_hash(by_id[str(qid)])
            if name == "stale":
                h = "f" * 64  # English edited after translation
            entries.append(
                (qid, f"Ktorá krajina pretekala vo farbe rosso corsa? [{name}]", h)
            )
        assert (
            await ingest_job(
                translation_engine, _job(tmp_path, entries), log=lambda _m: None
            )
            == 5
        )

        _Checker.verdicts = {
            str(qids["flip"]): "translation_flip",
            str(qids["unavailable"]): "unavailable",
        }
        _Judge.results = {
            "Ktorá krajina pretekala vo farbe rosso corsa? [critical]": JudgeResult(
                verdict="defects",
                findings=[
                    Finding(
                        severity="critical", category="answer_leak", span="x", note="x"
                    )
                ],
            )
        }
        outcomes = await ver.verify_rows(
            translation_engine, "sk", limit=50, concurrency=2, log=lambda _m: None
        )
        assert outcomes == {"approved": 1, "rejected": 2, "pending": 1, "stale": 1}

        async with translation_engine.connect() as conn:
            state = {
                str(qid): (status, langs)
                for qid, status, langs in (
                    await conn.execute(
                        text(
                            "SELECT t.question_id, t.status, q.approved_languages "
                            "FROM question_translations t JOIN questions q ON q.id = t.question_id "
                            "WHERE t.question_id = ANY(:ids)"
                        ),
                        {"ids": list(qids.values())},
                    )
                ).all()
            }
        assert state[str(qids["ok"])] == ("approved", ["sk"])
        assert state[str(qids["flip"])] == ("rejected", [])
        assert state[str(qids["critical"])] == ("rejected", [])
        assert state[str(qids["unavailable"])] == ("pending", [])
        assert state[str(qids["stale"])] == ("stale", [])

        # Ingesting a re-translation of the approved row drops the gate again.
        job2 = _job(
            tmp_path,
            [
                (
                    qids["ok"],
                    "Ktorá krajina pretekala vo farbe rosso corsa? [v2]",
                    entries[0][2],
                )
            ],
            job_id="sk-verify-2",
        )
        assert await ingest_job(translation_engine, job2, log=lambda _m: None) == 1
        async with translation_engine.connect() as conn:
            status, langs = (
                await conn.execute(
                    text(
                        "SELECT t.status, q.approved_languages FROM question_translations t "
                        "JOIN questions q ON q.id = t.question_id WHERE t.question_id = :qid"
                    ),
                    {"qid": qids["ok"]},
                )
            ).one()
        assert (status, langs) == ("pending", [])
    finally:
        await delete_questions(translation_engine, list(qids.values()))
