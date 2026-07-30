"""Legal pages must stay publicly reachable at their exact URLs.

The App Store listing and the iOS paywall/settings link to these URLs;
moving or auth-gating them breaks App Review compliance (Guideline 3.1.2
requires privacy-policy and terms links for auto-renewable subscriptions).
"""

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import app


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("path", "required_fragments"),
    [
        (
            "/legal/privacy",
            ["Zásady ochrany súkromia", "Privacy Policy", "michal.kalis@gmail.com"],
        ),
        (
            "/legal/terms",
            ["Podmienky používania", "Terms of Use", "automaticky obnovuje"],
        ),
        ("/legal/support", ["Podpora / Support", "michal.kalis@gmail.com"]),
    ],
)
async def test_legal_page_public_and_complete(
    path: str, required_fragments: list[str]
) -> None:
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get(path)

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/html")
    for fragment in required_fragments:
        assert fragment in response.text
