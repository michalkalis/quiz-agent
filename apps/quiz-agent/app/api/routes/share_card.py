"""The link page of a shared daily challenge, with its score card (#249.6).

Chat apps build a link preview from a page's Open Graph tags, and trubbo.app
is static (GitHub Pages), so it cannot carry one share's score. A daily
challenge is therefore shared as ``https://api.trubbo.app/play?s=TOKEN``:
this page answers with the tags and the ``og:image`` below it, and is also a
universal link (``/.well-known/apple-app-site-association`` here), so a friend
with the app lands in it exactly as from trubbo.app. A browser without the app
is sent on to the static play page (the App Store button).

Public, read-only, never carries a question or an answer. An unknown token,
another kind of share or a failing lookup still gets a page and a card, only
a generic one: a preview must never be an error.
"""

from __future__ import annotations

import re
from html import escape
import logging
from typing import Optional, Tuple

from fastapi import APIRouter, Query, Request, Response
from fastapi.concurrency import run_in_threadpool

from ...db.models import SharedQuiz
from ...rate_limit import limiter
from ...shared_quiz.service import ShareError
from ...shared_quiz.card import (
    CardData,
    HEIGHT,
    WIDTH,
    og_description,
    og_title,
    render_cached,
)
from ..deps import get_shared_quiz

logger = logging.getLogger(__name__)
router = APIRouter()

SITE = "https://api.trubbo.app"
STATIC_PLAY = "https://trubbo.app/play"
_TOKEN = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
_LOCALE = {"sk": "sk_SK", "cs": "cs_CZ", "uk": "uk_UA"}
_OPEN = {
    "sk": "Otvoriť v Trubbe",
    "cs": "Otevřít v Trubbu",
    "uk": "Відкрити в Trubbo",
}
_ALT = {
    "sk": "Skóre dennej výzvy v Trubbe",
    "cs": "Skóre denní výzvy v Trubbu",
    "uk": "Результат щоденного виклику в Trubbo",
}

# Same file as apps/website/public/.well-known/apple-app-site-association
# for /play (a test keeps them alike).
AASA = {
    "applinks": {
        "details": [
            {
                "appIDs": ["KAGWHPZZFQ.com.missinghue.hangs.beta"],
                "components": [{"/": "/play", "?": {"s": "?*"}}],
            },
            {
                "appIDs": ["KAGWHPZZFQ.com.missinghue.hangs"],
                "components": [{"/": "/play", "?": {"s": "?*"}}],
            },
        ]
    }
}


def card_data(share: Optional[SharedQuiz]) -> CardData:
    """What the card shows for a share; the generic card for anything but a
    daily that has the sender's result."""
    if share is None or share.kind != "daily" or share.sender_score is None:
        return CardData(language=getattr(share, "language", None) or "en")
    marks = tuple(share.sender_marks or ())
    total = share.sender_total or len(share.question_ids) or len(marks)
    day = share.challenge_date
    return CardData(
        language=share.language,
        score=share.sender_score,
        total=total,
        marks=marks,
        month=day.month if day else None,
        day=day.day if day else None,
        name=share.sender_name,
    )


async def _lookup(request: Request, token: str) -> Tuple[Optional[SharedQuiz], bool]:
    """(share, failed). Unknown token: (None, False), a stable answer. A failing
    lookup (database down, no service): (None, True), which callers must not
    let a cache keep under the share's permanent URL."""
    service = get_shared_quiz(request)
    if not _TOKEN.match(token):
        return None, False
    if service is None:
        return None, True
    try:
        return await service.by_token(token), False
    except ShareError:
        return None, False
    except Exception:
        logger.warning("share card lookup failed", exc_info=True)
        return None, True


def _cache(failed: bool, stable: str) -> str:
    return "no-store" if failed else stable


def page(data: CardData, token: str) -> str:
    """The HTML: Open Graph tags for chat apps, a hop to the static play page
    for browsers. Every value is escaped."""
    q = escape(token if _TOKEN.match(token) else "", quote=True)
    title, desc = escape(og_title(data)), escape(og_description(data))
    image = f"{SITE}/og/play/{q}.png" if q else f"{SITE}/og/play/generic.png"
    lang = escape(data.language, quote=True)
    target = f"{STATIC_PLAY}?s={q}" if q else STATIC_PLAY
    open_label = escape(_OPEN.get(data.language, "Open in Trubbo"))
    alt = escape(_ALT.get(data.language, "Daily challenge score in Trubbo"))
    locale = _LOCALE.get(data.language, "en_US")
    return f"""<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="robots" content="noindex">
<meta name="description" content="{desc}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Trubbo">
<meta property="og:title" content="{title}">
<meta property="og:description" content="{desc}">
<meta property="og:locale" content="{locale}">
<meta property="og:url" content="{SITE}/play?s={q}">
<meta property="og:image" content="{image}">
<meta property="og:image:type" content="image/png">
<meta property="og:image:width" content="{WIDTH}">
<meta property="og:image:height" content="{HEIGHT}">
<meta property="og:image:alt" content="{alt}">
<meta name="twitter:card" content="summary_large_image">
<meta name="apple-itunes-app" content="app-id=6762482437">
<style>
body{{margin:0;padding:16px;font-family:-apple-system,system-ui,sans-serif;background:#E8EAEE;color:#111216;text-align:center}}
img{{max-width:100%;height:auto;border-radius:16px}}
a.open{{display:block;max-width:420px;margin:20px auto;padding:16px 28px;border-radius:28px;background:#111216;color:#fff;font-size:18px;font-weight:700;text-decoration:none}}
</style>
</head>
<body>
<h1>{title}</h1>
<img src="{image}" alt="{alt}" width="{WIDTH}" height="{HEIGHT}">
<a class="open" href="{target}">{open_label}</a>
<script>
// iOS ignores a script redirect for universal links, so on iPhone and iPad the
// tap above is the way into the app (an older build opens it from a tap on
// another domain). Elsewhere the static page is the next step.
var ios=/iPhone|iPad|iPod/.test(navigator.userAgent)||(navigator.platform==="MacIntel"&&navigator.maxTouchPoints>1);
if(!ios)location.replace({target!r});
</script>
</body>
</html>
"""


@router.get("/play", include_in_schema=False)
@limiter.limit("120/minute")
async def play_page(
    request: Request,
    s: str = Query(default=""),
) -> Response:
    share, failed = await _lookup(request, s)
    return Response(
        page(card_data(share), s),
        media_type="text/html",
        headers={"Cache-Control": _cache(failed, "public, max-age=300")},
    )


@router.get("/og/play/{token}.png", include_in_schema=False)
@limiter.limit("120/minute")
async def play_card(request: Request, token: str) -> Response:
    """Stable per share (chat apps cache a preview image hard); a share never
    changes, so neither does its image."""
    share, failed = await _lookup(request, token)
    png = await run_in_threadpool(render_cached, card_data(share))
    return Response(
        png,
        media_type="image/png",
        headers={"Cache-Control": _cache(failed, "public, max-age=86400")},
    )


@router.get("/.well-known/apple-app-site-association", include_in_schema=False)
async def apple_app_site_association() -> dict:
    """Universal links for the play page above. Apple fetches it without a
    redirect and wants JSON."""
    return AASA
