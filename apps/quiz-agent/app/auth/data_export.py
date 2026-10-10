"""The personal-data trail for the GDPR export (Art. 15/20, #193 — beta hardening).

Reads what ``erase_account`` / ``erase_anonymous`` remove or unlink — in-app
feedback, analytics events and custom pack orders — for every subject id the
person used (the account plus its linked anonymous ids, or just the anon). Sign-in
does not re-key these rows, so pre-sign-in data only shows up under the anon ids.

Binary attachments (screenshot, dictation audio) are never embedded: each one is
listed by kind and content type under its feedback entry, which carries the id
and timestamp. Pack orders live in quiz-pack-api's tables in the same Postgres
and are read with Core ``text()``, the same path the erasure uses, so quiz-agent
never imports pack-api models. Rows are returned as dicts shaped like the export
response records.
"""

from __future__ import annotations

from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from ..db.models import AnalyticsEvent, Feedback, VoiceSample


async def export_trail(session: AsyncSession, subject_ids: list[str]) -> dict:
    return {
        "feedback": await _feedback(session, subject_ids),
        "analytics_events": await _analytics_events(session, subject_ids),
        "pack_orders": await _pack_orders(session, subject_ids),
        "voice_samples": await _voice_samples(session, subject_ids),
    }


async def _voice_samples(session: AsyncSession, subject_ids: list[str]) -> list[dict]:
    """#197 car answer recordings: metadata + sidecar (incl. what was heard);
    the audio is listed, not embedded — it sits in private storage."""
    rows = (
        (
            await session.execute(
                select(VoiceSample)
                .where(VoiceSample.user_id.in_(subject_ids))
                .order_by(VoiceSample.created_at)
            )
        )
        .scalars()
        .all()
    )
    return [
        {
            "id": r.id,
            "created_at": r.created_at,
            "session_id": r.session_id,
            "question_id": r.question_id,
            "language": r.language,
            "sidecar": r.sidecar,
            "label": r.label,
            "audio": {"content_type": "audio/wav", "bytes": r.audio_bytes},
        }
        for r in rows
    ]


async def _feedback(session: AsyncSession, subject_ids: list[str]) -> list[dict]:
    rows = (
        await session.execute(
            select(
                Feedback.id,
                Feedback.created_at,
                Feedback.message,
                Feedback.metadata_,
                Feedback.app_version,
                Feedback.logs,
                Feedback.screenshot.is_not(None).label("has_screenshot"),
                Feedback.screenshot_content_type,
                Feedback.audio.is_not(None).label("has_audio"),
                Feedback.audio_content_type,
            )
            .where(Feedback.user_id.in_(subject_ids))
            .order_by(Feedback.created_at)
        )
    ).all()
    return [
        {
            "id": r.id,
            "created_at": r.created_at,
            "message": r.message,
            "metadata": r.metadata_,
            "app_version": r.app_version,
            "logs": r.logs,
            "attachments": [
                {"kind": kind, "content_type": content_type}
                for kind, present, content_type in (
                    ("screenshot", r.has_screenshot, r.screenshot_content_type),
                    ("audio", r.has_audio, r.audio_content_type),
                )
                if present
            ],
        }
        for r in rows
    ]


async def _analytics_events(
    session: AsyncSession, subject_ids: list[str]
) -> list[dict]:
    rows = (
        (
            await session.execute(
                select(AnalyticsEvent)
                .where(AnalyticsEvent.subject_id.in_(subject_ids))
                .order_by(AnalyticsEvent.occurred_at)
            )
        )
        .scalars()
        .all()
    )
    return [
        {
            "name": e.name,
            "occurred_at": e.occurred_at,
            "session_id": e.session_id,
            "source": e.source,
            "app_version": e.app_version,
            "properties": e.properties,
        }
        for e in rows
    ]


async def _pack_orders(session: AsyncSession, subject_ids: list[str]) -> list[dict]:
    orders: list[dict] = []
    for subject_id in subject_ids:
        rows = await session.execute(
            text(
                "SELECT id, created_at, product_id, prompt, category, theme, "
                "language, target_count, status, delivered_at, pack_id "
                "FROM generation_orders WHERE user_id = :uid"
            ),
            {"uid": subject_id},
        )
        orders.extend(dict(r._mapping) for r in rows)
    return sorted(orders, key=lambda o: o["created_at"])
