"""In-memory session manager with TTL and automatic cleanup."""

import uuid
import asyncio
from datetime import datetime, timedelta, timezone
from typing import Dict, Optional
from threading import Lock

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../../..", "packages/shared"))

from quiz_shared.models.session import QuizSession
from quiz_shared.models.participant import Participant


class SessionManager:
    """Manages quiz sessions in memory with automatic expiration.

    Features:
    - In-memory storage (fast, simple)
    - TTL-based expiration (30 min default)
    - Automatic cleanup of expired sessions
    - Thread-safe operations
    - Multiplayer-ready (supports participants)
    """

    def __init__(self, cleanup_interval: int = 300):
        """Initialize session manager.

        Args:
            cleanup_interval: Seconds between cleanup runs (default: 5 min)
        """
        self._sessions: Dict[str, QuizSession] = {}
        self._lock = Lock()
        self._cleanup_interval = cleanup_interval
        self._cleanup_task: Optional[asyncio.Task] = None

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
                print(f"Cleanup error: {e}")

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
                print(f"Cleaned up {len(expired)} expired sessions")

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

        return session

    def get_session(self, session_id: str) -> Optional[QuizSession]:
        """Get session by ID.

        Args:
            session_id: Session ID

        Returns:
            QuizSession or None if not found/expired
        """
        with self._lock:
            session = self._sessions.get(session_id)

        if session and session.expires_at < datetime.now(timezone.utc):
            # Expired, remove it
            self.delete_session(session_id)
            return None

        return session

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
