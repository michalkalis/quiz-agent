"""The answer flow of a room (#212.2): everyone answers the same question, the
server closes it (all answered or time up), grades every answer with the solo
evaluator and scores it; the host then moves on.

There is no server timer: the first request after the deadline closes the
question. Closing is idempotent under the session lock, so a second attempt
(another machine, a retried poll) finds it closed and does nothing.
"""

from __future__ import annotations

import asyncio
import logging

from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.room import RoomAnswer, RoomRound
from quiz_shared.models.session import QuizSession
from quiz_shared.utils.text_normalization import normalize_text

from ..evaluation.evaluator import UNMATCHED
from ..quiz.flow import FlowResult, QuizFlowService
from ..serializers import session_translation, translated_question_view
from ..session.manager import SessionManager
from . import rounds
from .service import RoomError, member
from .store import RoomStore

logger = logging.getLogger(__name__)


class RoomPlay:
    def __init__(
        self, sessions: SessionManager, store: RoomStore, flow: QuizFlowService
    ) -> None:
        self.sessions = sessions
        self.store = store
        self.flow = flow
        # Strong refs to background closes started by polls (asyncio keeps
        # only weak ones); the set of session ids dedupes them per machine.
        self._tasks: set[asyncio.Task] = set()
        self._closing: set[str] = set()

    async def _session_id(self, room_id: str) -> str:
        room = await self.store.get(room_id, rounds.now())
        if room is None:
            raise RoomError(404, "Game not found")
        return room.session_id

    async def _load(self, session_id: str, subject_id: str):
        session = await self.sessions.get_session(session_id)
        you = member(session, subject_id) if session else None
        if session is None or you is None or session.room_game is None:
            raise RoomError(404, "Game not found")
        return session, you

    @staticmethod
    def _round(session: QuizSession, question_id: str) -> RoomRound:
        rnd = session.room_game.current
        if rnd is None or rnd.question_id != question_id:
            raise RoomError(409, "Not the current question")
        return rnd

    async def open(self, room_id: str, subject_id: str, question_id: str) -> None:
        """The host's phone finished reading the question aloud: start the
        answer clock. Repeats are no-ops ("read again" must not reset it)."""
        session_id = await self._session_id(room_id)
        async with self.sessions.session_lock(session_id):
            session, you = await self._load(session_id, subject_id)
            if not you.is_host:
                raise RoomError(403, "Only the host can start the answer time")
            rnd = self._round(session, question_id)
            if rnd.opened_at is None and not rnd.closed:
                rnd.opened_at = rounds.now()
                await self.sessions.update_session(session)

    async def settings(
        self,
        room_id: str,
        subject_id: str,
        *,
        reveal_mode: str | None = None,
        thinking_seconds: int | None = None,
        reads_aloud: bool | None = None,
    ) -> None:
        """Host: change the game's rules (#213.8). The answer time applies from
        the next question; when answers show only before the first one."""
        session_id = await self._session_id(room_id)
        async with self.sessions.session_lock(session_id):
            session, you = await self._load(session_id, subject_id)
            if not you.is_host:
                raise RoomError(403, "Only the host can change the rules")
            game = session.room_game
            if reveal_mode is not None and reveal_mode != game.reveal_mode:
                if session.phase != SessionPhase.IDLE:
                    raise RoomError(409, "Answers can change only before the game")
                game.reveal_mode = reveal_mode
            if thinking_seconds is not None:
                game.thinking_seconds = thinking_seconds
            if reads_aloud is not None:
                game.reads_aloud = reads_aloud
            await self.sessions.update_session(session)

    async def answer(
        self, room_id: str, subject_id: str, question_id: str, text: str
    ) -> None:
        """One answer per player and question, final once sent. The last
        missing answer closes the question right away."""
        session_id = await self._session_id(room_id)
        async with self.sessions.session_lock(session_id):
            session, you = await self._load(session_id, subject_id)
            rnd = self._round(session, question_id)
            at = rounds.now()
            if you.participant_id in rnd.answers:
                raise RoomError(409, "Already answered")
            if not rounds.accepts_answers(session.room_game, rnd, at):
                raise RoomError(409, "Time is up")
            rnd.answers[you.participant_id] = RoomAnswer(answer=text.strip(), at=at)
            if rounds.all_answered(session, rnd):
                await self._grade(session, rnd)
            await self.sessions.update_session(session)

    async def away(self, room_id: str, subject_id: str, question_id: str) -> None:
        """#212.4: the player's app went to the background during the question
        (the app does not send it during a phone call). Never changes points."""
        session_id = await self._session_id(room_id)
        async with self.sessions.session_lock(session_id):
            session, you = await self._load(session_id, subject_id)
            rnd = self._round(session, question_id)
            if not rnd.closed and you.participant_id not in rnd.away:
                rnd.away.append(you.participant_id)
                await self.sessions.update_session(session)

    async def next(self, room_id: str, subject_id: str) -> None:
        """The host moves on: the next question for everyone, or the end."""
        session_id = await self._session_id(room_id)
        async with self.sessions.session_lock(session_id):
            session, you = await self._load(session_id, subject_id)
            if not you.is_host:
                raise RoomError(403, "Only the host can move on")
            rnd = session.room_game.current
            if session.phase != SessionPhase.ASKING or rnd is None:
                raise RoomError(409, "The game is not running")
            if not rnd.closed:
                if not rounds.close_due(session, rounds.now()):
                    raise RoomError(409, "Players are still answering")
                await self._grade(session, rnd)
            await self._advance(session)

    async def _advance(self, session: QuizSession) -> None:
        """Same order as the solo flow after an answer: question count, the
        host's monthly limit (M1: only the host's), then the next question."""
        flow = self.flow
        if len(session.asked_question_ids) >= session.max_questions:
            return await self._finish(session, "max_questions")
        tracker = flow.usage_tracker
        if tracker and session.user_id and not session.is_quota_exempt:
            allowed, _, _ = await tracker.check_limit(session.user_id)
            if not allowed:
                usage = await tracker.get_usage(session.user_id)
                flow.analytics.emit(
                    "quota_hit",
                    subject_id=session.user_id,
                    session_id=session.session_id,
                    properties={
                        "stage": "mid_quiz",
                        "questions_used": usage["questions_used"],
                        "questions_limit": usage["questions_limit"],
                        "plan": usage["plan"],
                    },
                )
                return await self._finish(session, "usage_limit")
        question = await flow.question_retriever.get_next_question(session)
        if question is None:
            return await self._finish(session, "no_more_questions")
        # Charges the host, opens the next round (rounds.open_round) and warms
        # the read-aloud audio, exactly as a solo next question.
        await flow._advance_to_question(
            session, question, FlowResult(), include_audio=True
        )

    async def _finish(self, session: QuizSession, reason: str) -> None:
        session.transition(to=SessionPhase.FINISHED, caller=f"rooms.next:{reason}")
        session.room_game.finished_reason = reason
        await self.sessions.update_session(session)
        self.flow._emit_completed(session, reason)

    def close_if_due(self, session: QuizSession) -> None:
        """Called by the state poll, which never waits on the session lock:
        the close runs in the background and a later poll sees the result."""
        sid = session.session_id
        if sid in self._closing or not rounds.close_due(session, rounds.now()):
            return
        self._closing.add(sid)
        task = asyncio.create_task(self._close(sid))
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def _close(self, session_id: str) -> None:
        try:
            async with self.sessions.session_lock(session_id):
                session = await self.sessions.get_session(session_id)
                game = session.room_game if session else None
                if game and rounds.close_due(session, rounds.now()):
                    await self._grade(session, game.current)
                    await self.sessions.update_session(session)
        except Exception:
            logger.exception("Room close failed for session %s", session_id)
        finally:
            self._closing.discard(session_id)

    async def _grade(self, session: QuizSession, rnd: RoomRound) -> None:
        """Grade every answer with the solo evaluator. Equal answers (after
        normalization) are graded once; the distinct ones run concurrently."""
        flow = self.flow
        question = await flow.question_retriever.get(rnd.question_id)
        translation = session_translation(session, rnd.question_id)
        view = translated_question_view(question, translation)
        distinct: dict[str, str] = {}
        for a in rnd.answers.values():
            distinct.setdefault(normalize_text(a.answer), a.answer)
        verdicts = await asyncio.gather(
            *(
                flow.answer_evaluator.evaluate(
                    user_answer=text, question=view, question_text=view.question
                )
                for text in distinct.values()
            )
        )
        by_key = dict(zip(distinct, verdicts))
        for pid, a in rnd.answers.items():
            result, points = by_key[normalize_text(a.answer)]
            if result == UNMATCHED:
                # A tapped option always matches; anything else is wrong.
                result, points = "incorrect", 0.0
            a.result, a.points = result, points
            p = session.get_participant(pid)
            if p is None:
                continue  # left or removed after answering
            p.score += points
            p.answered_count += result != "skipped"
            p.correct_count += result == "correct"
            p.last_answer, p.last_result = a.answer, result
            flow.analytics.emit(
                "answer_evaluated",
                subject_id=p.user_id,
                session_id=session.session_id,
                properties={
                    "question_id": rnd.question_id,
                    "result": result,
                    "category": question.category,
                    "question_type": question.type,
                    "difficulty": question.difficulty,
                    "route": "text",
                    "is_regrade": False,
                    "question_index": rnd.number,
                    "multiplayer": True,
                    "room_id": session.room_code,
                },
            )
        rnd.correct_answer = await flow._correct_answer_display(
            question, translation, session
        )
        rnd.explanation = view.explanation
        rnd.closed = True
