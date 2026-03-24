"""In-memory session manager with TTL and automatic cleanup."""

import copy
import logging
import uuid
import asyncio
from datetime import datetime, timedelta, timezone
from typing import Dict, Optional
from threading import Lock

logger = logging.getLogger(__name__)

from quiz_shared.models.session import QuizSession
from quiz_shared.models.participant import Participant


class SessionManager:
    """Manages quiz sessions in memory with automatic expiration.

    Features:
    - In-memory storage (fast, simple)
    - Write-through SQLite persistence (survives restarts)
    - TTL-based expiration (30 min default)
    - Automatic cleanup of expired sessions
    - Thread-safe operations
    - Multiplayer-ready (supports participants)
    """

    def __init__(self, cleanup_interval: int = 300, sql_client=None):
        """Initialize session manager.

        Args:
            cleanup_interval: Seconds between cleanup runs (default: 5 min)
            sql_client: Optional SQLClient for write-through persistence
        """
        self._sessions: Dict[str, QuizSession] = {}
        self._lock = Lock()
        self._cleanup_interval = cleanup_interval
        self._cleanup_task: Optional[asyncio.Task] = None
        self._sql_client = sql_client

    def _persist(self, session: QuizSession) -> None:
        """Write session to SQLite (best-effort, non-blocking)."""
        if self._sql_client:
            try:
                self._sql_client.save_session(
                    session.session_id, session.model_dump_json()
                )
            except Exception as e:
                logger.warning("Failed to persist session %s: %s", session.session_id, e)

    def _deactivate(self, session_id: str) -> None:
        """Mark session inactive in SQLite (best-effort)."""
        if self._sql_client:
            try:
                self._sql_client.deactivate_session(session_id)
            except Exception as e:
                logger.warning("Failed to deactivate session %s: %s", session_id, e)

    def reload_active_sessions(self) -> int:
        """Reload active sessions from SQLite on startup.

        Discards sessions that have already expired.

        Returns:
            Number of sessions reloaded
        """
        if not self._sql_client:
            return 0

        now = datetime.now(timezone.utc)
        rows = self._sql_client.load_active_sessions()
        reloaded = 0
        for session_id, data_json in rows:
            try:
                session = QuizSession.model_validate_json(data_json)
                if session.expires_at >= now:
                    with self._lock:
                        self._sessions[session_id] = session
                    reloaded += 1
                else:
                    self._sql_client.deactivate_session(session_id)
            except Exception as e:
                logger.warning("Failed to reload session %s: %s", session_id, e)

        if reloaded:
            logger.info("Reloaded %d active sessions from database", reloaded)
        return reloaded

    async def start_cleanup(self):
        """Start background cleanup task."""
        if self._cleanup_task is None:
            self._cleanup_task = asyncio.create_task(self._cleanup_loop())

    async def stop_cleanup(self):
        """Stop background cleanup task."""
        if self._cleanup_task:
            self._cleanup_task.cancel()
            try:
                await self._cleanup_task
            except asyncio.CancelledError:
                pass
            self._cleanup_task = None

    async def _cleanup_loop(self):
        """Background task to cleanup expired sessions."""
        while True:
            try:
                await asyncio.sleep(self._cleanup_interval)
                self._cleanup_expired()
            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error("Cleanup error: %s", e)

    def _cleanup_expired(self):
        """Remove expired sessions."""
        now = datetime.now(timezone.utc)
        with self._lock:
            expired = [
                sid for sid, session in self._sessions.items()
                if session.expires_at < now
            ]
            for sid in expired:
                del self._sessions[sid]
            if expired:
                logger.info("Cleaned up %d expired sessions", len(expired))
        for sid in expired:
            self._deactivate(sid)

    def create_session(
        self,
        max_questions: int = 10,
        difficulty: str = "medium",
        user_id: Optional[str] = None,
        mode: str = "single",
        ttl_minutes: int = 30
    ) -> QuizSession:
        """Create a new quiz session.

        Args:
            max_questions: Number of questions in quiz
            difficulty: Initial difficulty
            user_id: User ID (optional)
            mode: "single" or "multiplayer"
            ttl_minutes: Session expiry time

        Returns:
            New QuizSession

        Example:
            >>> manager = SessionManager()
            >>> session = manager.create_session(max_questions=10, difficulty="medium")
        """
        session_id = f"sess_{uuid.uuid4().hex[:12]}"

        session = QuizSession(
            session_id=session_id,
            user_id=user_id,
            mode=mode,
            max_questions=max_questions,
            current_difficulty=difficulty,
            phase="idle",
            expires_at=datetime.now(timezone.utc) + timedelta(minutes=ttl_minutes)
        )

        # For single-player, create default participant
        if mode == "single":
            participant = Participant(
                participant_id=f"p_{uuid.uuid4().hex[:8]}",
                user_id=user_id,
                display_name=user_id or "Player",
                is_host=True
            )
            session.participants = [participant]

        with self._lock:
            self._sessions[session_id] = session

        self._persist(session)
        return session

    def get_session(self, session_id: str) -> Optional[QuizSession]:
        """Get session by ID.

        Returns a deep copy so callers get an isolated snapshot.
        Mutations won't affect the stored session until update_session() is called.

        Args:
            session_id: Session ID

        Returns:
            QuizSession (deep copy) or None if not found/expired
        """
        with self._lock:
            session = self._sessions.get(session_id)

        if session and session.expires_at < datetime.now(timezone.utc):
            # Expired, remove it
            self.delete_session(session_id)
            return None

        return copy.deepcopy(session) if session else None

    def update_session(self, session: QuizSession) -> bool:
        """Update session state.

        Args:
            session: Updated session object

        Returns:
            True if successful, False if session not found
        """
        if session.session_id not in self._sessions:
            return False

        # Update timestamp
        session.updated_at = datetime.now(timezone.utc)

        with self._lock:
            self._sessions[session.session_id] = session

        self._persist(session)
        return True

    def delete_session(self, session_id: str) -> bool:
        """Delete a session.

        Args:
            session_id: Session ID

        Returns:
            True if deleted, False if not found
        """
        with self._lock:
            if session_id in self._sessions:
                del self._sessions[session_id]
                self._deactivate(session_id)
                return True
            return False

    def extend_session(
        self,
        session_id: str,
        minutes: int = 30
    ) -> bool:
        """Extend session expiry time.

        Args:
            session_id: Session ID
            minutes: Minutes to extend

        Returns:
            True if successful
        """
        session = self.get_session(session_id)
        if not session:
            return False

        session.expires_at = datetime.now(timezone.utc) + timedelta(minutes=minutes)
        return self.update_session(session)

    def get_active_sessions_count(self) -> int:
        """Get count of active (non-expired) sessions."""
        now = datetime.now(timezone.utc)
        with self._lock:
            active = sum(
                1 for session in self._sessions.values()
                if session.expires_at >= now
            )
        return active

    # Multiplayer support methods

    def add_participant(
        self,
        session_id: str,
        display_name: str,
        user_id: Optional[str] = None
    ) -> Optional[Participant]:
        """Add participant to multiplayer session.

        Args:
            session_id: Session ID
            display_name: Participant display name
            user_id: User ID (optional)

        Returns:
            Created Participant or None if session not found
        """
        session = self.get_session(session_id)
        if not session:
            return None

        participant = Participant(
            participant_id=f"p_{uuid.uuid4().hex[:8]}",
            user_id=user_id,
            display_name=display_name,
            is_host=len(session.participants) == 0  # First participant is host
        )

        session.participants.append(participant)
        self.update_session(session)

        return participant

    def remove_participant(
        self,
        session_id: str,
        participant_id: str
    ) -> bool:
        """Remove participant from session.

        Args:
            session_id: Session ID
            participant_id: Participant ID

        Returns:
            True if removed
        """
        session = self.get_session(session_id)
        if not session:
            return False

        session.participants = [
            p for p in session.participants
            if p.participant_id != participant_id
        ]

        # If host left, assign new host
        if session.participants and not any(p.is_host for p in session.participants):
            session.participants[0].is_host = True

        self.update_session(session)
        return True
