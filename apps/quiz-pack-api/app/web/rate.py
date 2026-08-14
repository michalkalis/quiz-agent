"""`GET /web/rate/{batch_id}` — the multi-rater blind rating page (issue #154).

A SEPARATE router from `web/routes.py` on purpose. That module gates every
route with `require_admin` at the router level, which is exactly right for the
admin question tool and exactly wrong here: raters are people the founder sends
a link to, and D25 rules out any auth system. The batch UUID is the capability,
so this router carries no dependency — and because the gate is expressed as a
router-level dependency rather than per-route, the split is what keeps the
admin pages gated while this one is open.

The page only ever receives `RatingBatch.questions` (already blinded);
`mapping` stays on the row.
"""

from __future__ import annotations

import json
import os
from typing import Annotated, Optional

from fastapi import APIRouter, Depends, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
from sqlalchemy.ext.asyncio import AsyncSession

from ..api.v1.ratings_store import load_batch
from ..db.session import get_session

templates = Jinja2Templates(directory=os.path.join(os.path.dirname(__file__), "templates"))

# No `dependencies=[Depends(require_admin)]` — see the module docstring.
router = APIRouter(prefix="/web", tags=["web"])


def _json_for_script(value: object) -> str:
    """JSON safe to embed in a `<script>` block (no `</script>` breakout)."""
    return json.dumps(value, ensure_ascii=False).replace("</", "<\\/")


@router.get("/rate/{batch_id}", response_class=HTMLResponse)
async def rate_page(
    request: Request,
    batch_id: str,
    session: Annotated[AsyncSession, Depends(get_session)],
    rater: Optional[str] = None,
) -> HTMLResponse:
    """Serve the rating page for one batch. 404 on an unknown/malformed id."""
    batch = await load_batch(session, batch_id)

    return templates.TemplateResponse(
        "rate.html",
        {
            "request": request,
            "title": batch.title,
            "batch_id": str(batch.id),
            # Blinded payload only. `batch.mapping` is deliberately not passed.
            "boot_json": _json_for_script(
                {
                    "batch_id": str(batch.id),
                    "rater": (rater or "").strip(),
                    "questions": batch.questions,
                }
            ),
        },
    )
