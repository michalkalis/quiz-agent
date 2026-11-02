"""``GET /api/v1/public/fresh-questions`` — the website's unauthenticated feed (#223).

What the route itself must guarantee (row selection is proven against Postgres
in tests/db/test_public_fresh_questions.py): no login needed, only the three
quiz languages accepted, limit bounded so one call cannot dump the corpus, the
headline answer wins over the raw correct answer, and the response is cacheable
for the hourly-to-weekly cadence of the site build.
"""

from __future__ import annotations

from datetime import UTC, datetime

import pytest
from app.api.deps import get_question_retriever
from app.api.routes import public_questions
from app.rate_limit import limiter
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient

pytestmark = pytest.mark.asyncio

T = datetime(2026, 11, 2, 8, 0, tzinfo=UTC)


class FakeRetriever:
    def __init__(self, rows):
        self.rows = rows
        self.calls: list[tuple[str, int]] = []

    async def fresh_public_entertainment(self, language, limit):
        self.calls.append((language, limit))
        return self.rows


def _row(**kw):
    row = {
        "id": "11111111-1111-1111-1111-111111111111",
        "question": "Who?",
        "correct_answer": "Alice",
        "headline_answer": None,
        "explanation": "Because.",
        "source_url": "https://example.org/x",
        "created_at": T,
    }
    row.update(kw)
    return row


@pytest.fixture(autouse=True)
def _reset_limiter():
    limiter.reset()


async def _get(rows, query: str):
    retriever = FakeRetriever(rows)
    app = FastAPI()
    app.state.limiter = limiter
    app.include_router(public_questions.router, prefix="/api/v1")
    app.dependency_overrides[get_question_retriever] = lambda: retriever
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as c:
        resp = await c.get(f"/api/v1/public/fresh-questions{query}")
    return resp, retriever


async def test_shape_cache_header_and_defaults_need_no_auth():
    resp, retriever = await _get([_row()], "?language=sk")

    assert resp.status_code == 200
    assert resp.headers["cache-control"] == "public, max-age=3600"
    body = resp.json()
    assert body["language"] == "sk"
    assert body["questions"] == [
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "question": "Who?",
            "answer": "Alice",
            "explanation": "Because.",
            "source_url": "https://example.org/x",
            "created_at": T.isoformat(),
        }
    ]
    assert retriever.calls == [("sk", 10)]  # default limit


async def test_headline_answer_wins_and_list_answers_use_the_first():
    resp, _ = await _get(
        [
            _row(headline_answer="The Headline", correct_answer=["x", "y"]),
            _row(correct_answer=["First", "Second"]),
        ],
        "?language=en",
    )

    assert [q["answer"] for q in resp.json()["questions"]] == [
        "The Headline",
        "First",
    ]


@pytest.mark.parametrize("query", ["?language=de", "?language=xx", ""])
async def test_unknown_or_missing_language_is_rejected(query):
    resp, retriever = await _get([], query)

    assert resp.status_code == 422
    assert retriever.calls == []


@pytest.mark.parametrize("limit", [0, 21, -1])
async def test_limit_outside_1_to_20_is_rejected(limit):
    resp, retriever = await _get([], f"?language=cs&limit={limit}")

    assert resp.status_code == 422
    assert retriever.calls == []


async def test_limit_is_passed_through():
    _, retriever = await _get([], "?language=cs&limit=20")

    assert retriever.calls == [("cs", 20)]
