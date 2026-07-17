"""Sandbox JWS minter for integration tests (issue #33 Task 1.12).

Builds an in-memory P-256 root → intermediate → leaf chain and signs JWSs that
``AppleJWSVerifier`` accepts when configured with the corresponding test root.

Usage
-----
    from tests.fixtures.storekit.jws_minter import JWSMinter

    minter = JWSMinter()  # generates keys once

    # Build a verifier that trusts the minter's root:
    verifier = AppleJWSVerifier(minter.root_cert, "com.missinghue.hangs", "Sandbox")

    jws = minter.mint(transaction_id="tx-001", product_id="pack_10")

The minter is designed to be instantiated once per test session and shared
across fixtures; key generation is cheap (~5 ms) but avoids wasted work when
the same ``JWSMinter`` instance is reused.
"""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Optional

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.x509.oid import NameOID

from app.storekit.verifier import (
    APPLE_INTERMEDIATE_MARKER_OID,
    APPLE_LEAF_MARKER_OID,
)

_ONE_DAY = timedelta(days=1)
_TEN_YEARS = timedelta(days=3650)

# Default bundle + environment expected by the test verifier.
DEFAULT_BUNDLE_ID = "com.missinghue.hangs"
DEFAULT_ENVIRONMENT = "Sandbox"


def _b64url_nopad(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _make_cert(
    subject: x509.Name,
    issuer: x509.Name,
    subject_public_key: ec.EllipticCurvePublicKey,
    issuer_private_key: ec.EllipticCurvePrivateKey,
    *,
    is_ca: bool,
    marker_oid: Optional[x509.ObjectIdentifier] = None,
) -> x509.Certificate:
    now = datetime.now(timezone.utc)
    builder = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(subject_public_key)
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - _ONE_DAY)
        .not_valid_after(now + _TEN_YEARS)
        .add_extension(x509.BasicConstraints(ca=is_ca, path_length=None), critical=True)
    )
    if marker_oid is not None:
        builder = builder.add_extension(
            x509.UnrecognizedExtension(marker_oid, b""), critical=False
        )
    return builder.sign(private_key=issuer_private_key, algorithm=hashes.SHA256())


@dataclass
class JWSMinter:
    """Generates a self-signed test cert chain and mints ES256 JWSs from it.

    All certs share the same validity window (now-1d … now+10y) so tests that
    run long or in parallel don't hit expiry edge cases.
    """

    # Set in __post_init__
    root_cert: x509.Certificate = field(init=False)
    _chain_b64: list[str] = field(init=False)
    _leaf_private_key: ec.EllipticCurvePrivateKey = field(init=False)

    def __post_init__(self) -> None:
        root_key = ec.generate_private_key(ec.SECP256R1())
        root_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Test Apple Root CA")])
        self.root_cert = _make_cert(
            subject=root_name,
            issuer=root_name,
            subject_public_key=root_key.public_key(),
            issuer_private_key=root_key,
            is_ca=True,
        )

        int_key = ec.generate_private_key(ec.SECP256R1())
        int_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Test Apple WWDR Intermediate")])
        int_cert = _make_cert(
            subject=int_name,
            issuer=root_name,
            subject_public_key=int_key.public_key(),
            issuer_private_key=root_key,
            is_ca=True,
            marker_oid=APPLE_INTERMEDIATE_MARKER_OID,
        )

        leaf_key = ec.generate_private_key(ec.SECP256R1())
        leaf_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Test StoreKit Leaf")])
        leaf_cert = _make_cert(
            subject=leaf_name,
            issuer=int_name,
            subject_public_key=leaf_key.public_key(),
            issuer_private_key=int_key,
            is_ca=False,
            marker_oid=APPLE_LEAF_MARKER_OID,
        )

        self._leaf_private_key = leaf_key
        self._chain_b64 = [
            base64.b64encode(c.public_bytes(serialization.Encoding.DER)).decode("ascii")
            for c in (leaf_cert, int_cert, self.root_cert)
        ]

    def mint(
        self,
        transaction_id: str = "1000000000000001",
        product_id: str = "pack_10",
        bundle_id: str = DEFAULT_BUNDLE_ID,
        environment: str = DEFAULT_ENVIRONMENT,
        purchase_date_ms: Optional[int] = None,
    ) -> str:
        """Return a signed JWS string accepted by AppleJWSVerifier(self.root_cert, ...)."""
        if purchase_date_ms is None:
            purchase_date_ms = int(datetime.now(timezone.utc).timestamp() * 1000)

        payload = {
            "transactionId": transaction_id,
            "originalTransactionId": transaction_id,
            "productId": product_id,
            "bundleId": bundle_id,
            "purchaseDate": purchase_date_ms,
            "environment": environment,
        }
        header = {"alg": "ES256", "x5c": self._chain_b64}

        header_b64 = _b64url_nopad(json.dumps(header, separators=(",", ":")).encode())
        payload_b64 = _b64url_nopad(json.dumps(payload, separators=(",", ":")).encode())
        signing_input = f"{header_b64}.{payload_b64}".encode("ascii")

        der_sig = self._leaf_private_key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
        r, s = decode_dss_signature(der_sig)
        raw_sig = r.to_bytes(32, "big") + s.to_bytes(32, "big")
        sig_b64 = _b64url_nopad(raw_sig)

        return f"{header_b64}.{payload_b64}.{sig_b64}"
