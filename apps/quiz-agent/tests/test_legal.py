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
            [
                "Zásady ochrany súkromia",
                "Zásady ochrany soukromí",
                "Privacy Policy",
                "missinghue s.r.o.",
                "07288093",
                "hello@missinghue.com",
                "uoou.gov.cz",
            ],
        ),
        (
            "/legal/terms",
            [
                "Podmienky používania",
                "Podmínky používání",
                "Terms of Use",
                "automaticky obnovuje",
                "missinghue s.r.o.",
                "právom Českej republiky",
                "law of the Czech Republic",
            ],
        ),
        ("/legal/support", ["Podpora / Support", "hello@missinghue.com"]),
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
    # The App Store developer account is the company: the founder's personal
    # identity and mailbox must not reappear as operator/contact.
    assert "michal.kalis" not in response.text
    assert "Michal Kalis" not in response.text
