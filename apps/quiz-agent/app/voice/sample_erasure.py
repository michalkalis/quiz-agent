"""Erase a person's car answer recordings (GDPR Art. 17; #197 on top of #193).

Called by ``DELETE /auth/me`` inside its transaction, before the commit — the
same rule the route already applies to the ratings store: an outside store is
cleaned first, so if it fails nothing is committed and the person can simply
retry. Order inside: R2 objects first, then the rows. If R2 refuses, the rows
stay (still pointing at audio that still exists) and the route answers 503;
a row is never dropped while its audio lives on unlisted. Deleting an object
that is already gone succeeds, so a retry after a half-finished attempt is safe.
"""

from __future__ import annotations

import asyncio
import logging

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..db.models import VoiceSample
from .sample_storage import VoiceSampleStorage

logger = logging.getLogger(__name__)


class VoiceSampleErasureFailed(RuntimeError):
    """R2 could not delete the audio; the erasure must not commit."""


async def erase_voice_samples(
    session: AsyncSession, subject_ids: list[str], storage: VoiceSampleStorage
) -> int:
    """Delete every recording (audio + row) of ``subject_ids``; returns how many."""
    keys = list(
        (
            await session.execute(
                select(VoiceSample.r2_key).where(VoiceSample.user_id.in_(subject_ids))
            )
        )
        .scalars()
        .all()
    )
    if not keys:
        return 0  # nearly everyone: R2 is never touched, nor needs to be configured
    try:
        await asyncio.to_thread(storage.delete, keys)
    except Exception as exc:
        logger.error(
            "Voice sample erasure failed for %d recording(s) of %s: %s",
            len(keys),
            subject_ids,
            exc,
        )
        raise VoiceSampleErasureFailed(str(exc)) from exc
    await session.execute(
        delete(VoiceSample).where(VoiceSample.user_id.in_(subject_ids))
    )
    return len(keys)
