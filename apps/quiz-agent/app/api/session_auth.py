"""Ownership gate for every ``/sessions/{session_id}`` route (issue #144).

Sibling of ``routes.sessions._require_pack_ownership``: that one authorizes the
``pack_id`` a session is created with, this one authorizes every later use of the
session itself. Before #144 the session id was the *only* credential on the serve
path, so a leaked id (URL, client log, Sentry breadcrumb, support screenshot)
worked as a bearer token for someone else's paid pack, freemium quota and LLM/TTS
spend — the #96 broken-access-control fix was verified once at creation and never
again.

Semantics, mirroring ``_require_pack_ownership``:

* **404, never 403.** "not yours", "expired" and "never existed" are one answer,
  so a caller cannot probe which session ids are live. The real reason is logged
  server-side.
* **Fail closed.** A subject that cannot be *verified* — no bearer, the
  ``LEGACY_USER_ID_GRACE`` pass-through (``authenticated=False``,
  ``subject_id=None``), a route invoked without the dependency at all — is denied.
  The decision lives here rather than in per-route conditionals so there is one
  place to read and one place to change.
* **Owner-only** (founder decision, 2026-08-06, in-session). Multiplayer
  participants are far-future; when they arrive, the participant-scoped predicate
  is added *here* and every route inherits it without being touched.
"""

from __future__ import annotations

import logging
from typing import Any

from fastapi import HTTPException

from quiz_shared.models.session import QuizSession

logger = logging.getLogger(__name__)

# One message for every denial — see the 404-never-403 rule above.
_NOT_FOUND = "Session not found or expired"


def require_session_ownership(
    session: QuizSession | None,
    subject: Any,
    *,
    session_id: str,
) -> QuizSession:
    """Return ``session`` if ``subject`` owns it, else raise 404.

    ``subject`` is read defensively (``getattr``) rather than typed-and-trusted:
    a route that forgets ``Depends(require_auth_or_grace)`` passes the unresolved
    dependency object, and a caller that passes ``None`` means "no identity". Both
    must deny, not raise ``AttributeError`` into a 500 that a client could read as
    "the session exists".
    """
    if session is None:
        raise HTTPException(status_code=404, detail=_NOT_FOUND)

    subject_id = getattr(subject, "subject_id", None)
    authenticated = getattr(subject, "authenticated", False) is True
    if not authenticated or not subject_id:
        logger.warning(
            "Session access denied: subject not verifiable "
            "(authenticated=%s, subject_id=%s) for session=%s",
            authenticated,
            subject_id,
            session_id,
        )
        raise HTTPException(status_code=404, detail=_NOT_FOUND)

    if session.user_id != subject_id:
        logger.warning(
            "Session ownership denied: subject=%s is not the owner (%s) of session=%s",
            subject_id,
            session.user_id,
            session_id,
        )
        raise HTTPException(status_code=404, detail=_NOT_FOUND)

    return session
