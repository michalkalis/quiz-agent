"""Public legal pages (privacy policy, terms of use, support).

Served at the app root (no /api/v1) so the URLs are stable and human-readable:
these exact URLs are printed into the App Store listing and linked from the
iOS paywall/settings, so changing them is a breaking change.
"""

from pathlib import Path

from fastapi import APIRouter
from fastapi.responses import HTMLResponse

router = APIRouter(prefix="/legal", tags=["legal"])

_LEGAL_DIR = Path(__file__).resolve().parent.parent.parent / "legal"

_PAGES = {
    "privacy": (_LEGAL_DIR / "privacy.html").read_text(encoding="utf-8"),
    "terms": (_LEGAL_DIR / "terms.html").read_text(encoding="utf-8"),
    "support": (_LEGAL_DIR / "support.html").read_text(encoding="utf-8"),
}


@router.get("/privacy", response_class=HTMLResponse)
async def privacy_policy() -> str:
    """Privacy policy (SK + EN)."""
    return _PAGES["privacy"]


@router.get("/terms", response_class=HTMLResponse)
async def terms_of_use() -> str:
    """Terms of use / EULA (SK + EN)."""
    return _PAGES["terms"]


@router.get("/support", response_class=HTMLResponse)
async def support_page() -> str:
    """Support / contact page (SK + EN)."""
    return _PAGES["support"]
