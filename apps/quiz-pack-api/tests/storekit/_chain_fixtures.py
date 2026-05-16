"""Test cert chain + JWS factory for `app.storekit.verifier` tests.

Generates an in-memory P-256 root → intermediate → leaf chain at session
start. Each test asks the `jws_factory` for a JWS signed by that leaf,
tweaked with whatever payload/header overrides the test cares about. No
fixture certs are checked into the repo — they'd just expire.

The bundled Apple cert (`app/storekit/certs/AppleRootCA-G3.cer`) is **not**
required for these tests; `test_bundled_root_validity_runway` skips when the
file is absent so dev machines without `make fetch-apple-root` don't fail.
"""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Callable, Iterable, Optional

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.x509.oid import NameOID

ONE_DAY = timedelta(days=1)
TEN_YEARS = timedelta(days=3650)


def _b64url_nopad(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _make_cert(
    subject: x509.Name,
    issuer: x509.Name,
    subject_public_key: ec.EllipticCurvePublicKey,
    issuer_private_key: ec.EllipticCurvePrivateKey,
    *,
    is_ca: bool,
    not_before: datetime,
    not_after: datetime,
) -> x509.Certificate:
    builder = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(subject_public_key)
        .serial_number(x509.random_serial_number())
        .not_valid_before(not_before)
        .not_valid_after(not_after)
        .add_extension(x509.BasicConstraints(ca=is_ca, path_length=None), critical=True)
    )
    return builder.sign(private_key=issuer_private_key, algorithm=hashes.SHA256())


@dataclass(frozen=True)
class TestChain:
    """An in-memory P-256 root → intermediate → leaf chain.

    `chain_b64` is in JWS x5c order (leaf first, root last) so tests can drop
    it straight into a header. `root_cert_path` is a tmp file the verifier
    can read.
    """

    root_cert: x509.Certificate
    intermediate_cert: x509.Certificate
    leaf_cert: x509.Certificate
    leaf_private_key: ec.EllipticCurvePrivateKey
    chain_b64: list[str]
    root_cert_path: str


@pytest.fixture(scope="session")
def test_chain(tmp_path_factory) -> TestChain:
    now = datetime.now(timezone.utc)

    root_key = ec.generate_private_key(ec.SECP256R1())
    root_subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Test Apple Root CA")])
    root_cert = _make_cert(
        subject=root_subject,
        issuer=root_subject,
        subject_public_key=root_key.public_key(),
        issuer_private_key=root_key,
        is_ca=True,
        not_before=now - ONE_DAY,
        not_after=now + TEN_YEARS,
    )

    int_key = ec.generate_private_key(ec.SECP256R1())
    int_subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Test Apple WWDR Intermediate")])
    int_cert = _make_cert(
        subject=int_subject,
        issuer=root_subject,
        subject_public_key=int_key.public_key(),
        issuer_private_key=root_key,
        is_ca=True,
        not_before=now - ONE_DAY,
        not_after=now + TEN_YEARS,
    )

    leaf_key = ec.generate_private_key(ec.SECP256R1())
    leaf_subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Test StoreKit Leaf")])
    leaf_cert = _make_cert(
        subject=leaf_subject,
        issuer=int_subject,
        subject_public_key=leaf_key.public_key(),
        issuer_private_key=int_key,
        is_ca=False,
        not_before=now - ONE_DAY,
        not_after=now + TEN_YEARS,
    )

    chain_b64 = [
        base64.b64encode(c.public_bytes(serialization.Encoding.DER)).decode("ascii")
        for c in (leaf_cert, int_cert, root_cert)
    ]

    cert_dir = tmp_path_factory.mktemp("storekit_certs")
    root_cert_path = cert_dir / "test_root.cer"
    root_cert_path.write_bytes(root_cert.public_bytes(serialization.Encoding.DER))

    return TestChain(
        root_cert=root_cert,
        intermediate_cert=int_cert,
        leaf_cert=leaf_cert,
        leaf_private_key=leaf_key,
        chain_b64=chain_b64,
        root_cert_path=str(root_cert_path),
    )


def _default_payload() -> dict:
    purchase_ms = int(datetime(2026, 5, 12, 10, 0, tzinfo=timezone.utc).timestamp() * 1000)
    return {
        "transactionId": "1000000123456789",
        "originalTransactionId": "1000000123456789",
        "productId": "pack_20",
        "bundleId": "com.missinghue.hangs",
        "purchaseDate": purchase_ms,
        "environment": "Sandbox",
    }


JWSFactory = Callable[..., str]


@pytest.fixture
def make_jws(test_chain: TestChain) -> JWSFactory:
    """Returns `make_jws(payload_overrides=..., header_overrides=..., chain_b64=...)`.

    Signs with the test leaf key by default. Pass `chain_b64=[]` or a wrong
    chain to exercise broken-chain test cases. Pass `tamper_signature=True`
    to flip a bit in the signature after signing.
    """

    def _factory(
        payload_overrides: Optional[dict] = None,
        header_overrides: Optional[dict] = None,
        chain_b64: Optional[Iterable[str]] = None,
        tamper_signature: bool = False,
        signing_key: Optional[ec.EllipticCurvePrivateKey] = None,
    ) -> str:
        payload = _default_payload()
        if payload_overrides:
            payload.update(payload_overrides)

        header: dict = {
            "alg": "ES256",
            "x5c": list(chain_b64) if chain_b64 is not None else list(test_chain.chain_b64),
        }
        if header_overrides:
            header.update(header_overrides)

        header_b64 = _b64url_nopad(json.dumps(header, separators=(",", ":")).encode("utf-8"))
        payload_b64 = _b64url_nopad(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
        signing_input = f"{header_b64}.{payload_b64}".encode("ascii")

        key = signing_key or test_chain.leaf_private_key
        der_sig = key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
        r, s = decode_dss_signature(der_sig)
        raw_sig = bytearray(r.to_bytes(32, "big") + s.to_bytes(32, "big"))
        if tamper_signature:
            raw_sig[0] ^= 0x01
        sig_b64 = _b64url_nopad(bytes(raw_sig))

        return f"{header_b64}.{payload_b64}.{sig_b64}"

    return _factory
