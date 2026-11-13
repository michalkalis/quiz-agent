"""Which questions a shared quiz may carry (#232), decided when it is created.

The list always comes from what the server itself served the sender — never
from ids the app sends — and keeps only rows ANY recipient could be served the
same way, so a TestFlight sender can never pass a not-yet-approved question to
an App Store friend, and a friend reads the same wording as the sender.
"""

from __future__ import annotations

from typing import List

from quiz_shared.models.session import QuizSession

from ..retrieval.question_retriever import QuestionRetriever


async def corpus_ids(
    retriever: QuestionRetriever, ids: List[str], language: str
) -> List[str]:
    """``ids`` (order kept) that pass the daily-challenge candidate rule:
    approved (an App Store session's review gate), no image, not a pack row,
    and in sk/cs an English row only with a stored approved translation — a
    serve-time translation would word it differently per player."""
    probe = QuizSession(session_id="shared-quiz-snapshot", language=language)
    rows = []
    for qid in dict.fromkeys(ids):
        question = await retriever.shared_question(probe, qid)
        if question is not None:
            rows.append(question)
    if language != "en":
        english = [q.id for q in rows if q.language != language]
        translated = (
            await retriever.get_translations(english, language) if english else {}
        )
        rows = [q for q in rows if q.language == language or q.id in translated]
    return [q.id for q in rows]


async def pack_ids(
    retriever: QuestionRetriever, pack_id: str, asked: List[str] | None = None
) -> List[str]:
    """Questions of that one pack, minus rejected / archived / expired rows
    (the #225 pack-copy rule: pack rows are never approved, so the corpus gate
    would drop them all). With ``asked``: only those, in the order played."""
    playable = await retriever.pack_question_ids(pack_id)
    if asked is None:
        return playable
    allowed = set(playable)
    return [qid for qid in dict.fromkeys(asked) if qid in allowed]
