"""App Store Server API client, read-only (#207 207.6 — order check after a restore).

Only what the order reconciliation needs: a customer's transaction history
(v2, which unlike v1 includes consumables the app already finished). Auth is
an ES256 JWT signed with an **In-App Purchase key** from App Store Connect
(Users and Access → Integrations → In-App Purchase); App Store Connect API
team keys are not accepted by this API.

Every transaction Apple returns is a JWS; callers verify it with the same
`AppleJWSVerifier` the order endpoint uses, so the reconciliation trusts
nothing it could not trust at purchase time.
"""

from __future__ import annotations

import base64
import json
import time
from collections.abc import Iterator
from dataclasses import dataclass

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

BASE_URLS = {
    "Production": "https://api.storekit.itunes.apple.com",
    "Sandbox": "https://api.storekit-sandbox.itunes.apple.com",
}
# Apple caps the token lifetime at 60 min; a short one is plenty per run.
_TOKEN_TTL_S = 20 * 60
_MAX_PAGES = 200


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


@dataclass(frozen=True)
class ServerApiCredentials:
    key_id: str
    issuer_id: str
    private_key_pem: str  # contents of the downloaded SubscriptionKey_<id>.p8
    bundle_id: str


def make_token(creds: ServerApiCredentials, now: float | None = None) -> str:
    """ES256 JWT for the App Store Server API."""
    issued = int(now if now is not None else time.time())
    header = {"alg": "ES256", "kid": creds.key_id, "typ": "JWT"}
    payload = {
        "iss": creds.issuer_id,
        "iat": issued,
        "exp": issued + _TOKEN_TTL_S,
        "aud": "appstoreconnect-v1",
        "bid": creds.bundle_id,
    }
    signing_input = (
        _b64url(json.dumps(header, separators=(",", ":")).encode())
        + "."
        + _b64url(json.dumps(payload, separators=(",", ":")).encode())
    )
    key = serialization.load_pem_private_key(creds.private_key_pem.encode(), password=None)
    if not isinstance(key, ec.EllipticCurvePrivateKey):
        raise ValueError("App Store Server API key must be an EC (P-256) private key")
    der = key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der)
    signature = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return signing_input + "." + _b64url(signature)


class AppStoreServerClient:
    def __init__(
        self,
        creds: ServerApiCredentials,
        environment: str,
        *,
        http: httpx.Client | None = None,
    ) -> None:
        if environment not in BASE_URLS:
            raise ValueError(f"environment must be one of {sorted(BASE_URLS)}")
        self._creds = creds
        self._base = BASE_URLS[environment]
        self._http = http or httpx.Client(timeout=30.0)

    def transaction_history(
        self, transaction_id: str, *, product_type: str = "CONSUMABLE"
    ) -> Iterator[str]:
        """Every signed transaction (JWS) of the customer who made `transaction_id`."""
        params: dict[str, str] = {"productType": product_type}
        headers = {"Authorization": f"Bearer {make_token(self._creds)}"}
        url = f"{self._base}/inApps/v2/history/{transaction_id}"
        for _ in range(_MAX_PAGES):
            resp = self._http.get(url, params=params, headers=headers)
            resp.raise_for_status()
            body = resp.json()
            yield from body.get("signedTransactions", [])
            if not body.get("hasMore"):
                return
            params["revision"] = body["revision"]
        raise RuntimeError(f"history for {transaction_id} exceeded {_MAX_PAGES} pages")
