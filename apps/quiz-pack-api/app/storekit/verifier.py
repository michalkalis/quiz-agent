"""Offline StoreKit V2 JWS verifier (issue #33 Task 1.8).

Verifies a StoreKit V2 signed-transaction JWS (`alg=ES256`, x5c chain → Apple
G3 root) **offline**, without calling Apple's servers. The Apple root cert is
bundled at `certs/AppleRootCA-G3.cer` (download instructions in `certs/README.md`).

Verification steps:

1. Split JWS into header / payload / signature, base64url-decode each.
2. Header must have `alg=ES256` and a 1–4 entry `x5c` cert chain.
3. Each cert in `x5c` is parsed from DER (regular base64, **not** URL-safe).
4. Walk the chain: each cert is signed by the next, last cert is either the
   trusted root or directly signed by it. Every cert must be within its
   validity window.
5. Verify the JWS signature with the leaf cert's P-256 public key. JWS ECDSA
   signatures are raw `r||s` (64 bytes) — they must be re-encoded to DER for
   `cryptography`'s `verify`.
6. Decode payload, parse into `SignedTransaction`.
7. Cross-check `bundleId` and `environment` against the configured values.
   Mismatches raise `JWSWrongBundle` or `JWSInvalid` respectively, so the
   error log distinguishes "JWS for a different app" (security signal) from
   "Sandbox JWS hit a Production deployment" (config drift).

Subscription-only behavior (e.g. `expiresDate` enforcement) is deferred to
Phase 4 — see plan C2.
"""

from __future__ import annotations

import base64
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, Union

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
from pydantic import ValidationError

from .exceptions import JWSExpired, JWSInvalid, JWSWrongBundle
from .models import SignedTransaction

_MAX_CHAIN_LEN = 4


def _b64url_decode(segment: str) -> bytes:
    pad = "=" * (-len(segment) % 4)
    try:
        return base64.urlsafe_b64decode(segment + pad)
    except (ValueError, TypeError) as exc:
        raise JWSInvalid(f"invalid base64url segment: {exc}") from exc


class AppleJWSVerifier:
    """Verify a StoreKit V2 JWS against a configured Apple root + bundle id."""

    def __init__(
        self,
        root_cert: x509.Certificate,
        app_bundle_id: str,
        environment: str,
    ) -> None:
        self._root = root_cert
        self._root_der = root_cert.public_bytes(
            encoding=serialization.Encoding.DER
        )
        self._app_bundle_id = app_bundle_id
        self._environment = environment

    @classmethod
    def from_path(
        cls,
        root_cert_path: Union[str, Path],
        app_bundle_id: str,
        environment: str,
    ) -> "AppleJWSVerifier":
        path = Path(root_cert_path)
        if not path.is_file():
            raise FileNotFoundError(
                f"Apple root cert not found at {path}. "
                "Download AppleRootCA-G3.cer from "
                "https://www.apple.com/certificateauthority/ — "
                "see app/storekit/certs/README.md."
            )
        data = path.read_bytes()
        try:
            cert = x509.load_der_x509_certificate(data)
        except ValueError:
            cert = x509.load_pem_x509_certificate(data)
        return cls(cert, app_bundle_id, environment)

    def verify(self, jws: str) -> SignedTransaction:
        if not isinstance(jws, str) or jws.count(".") != 2:
            raise JWSInvalid("JWS must be a string with two '.' separators")
        header_b64, payload_b64, signature_b64 = jws.split(".")

        header = self._parse_header(header_b64)
        chain = self._parse_chain(header.get("x5c"))

        now = datetime.now(timezone.utc)
        self._verify_chain(chain, now)
        self._verify_jws_signature(chain[0], header_b64, payload_b64, signature_b64)

        try:
            payload = json.loads(_b64url_decode(payload_b64))
        except json.JSONDecodeError as exc:
            raise JWSInvalid(f"payload is not valid JSON: {exc}") from exc
        try:
            tx = SignedTransaction.model_validate(payload)
        except ValidationError as exc:
            raise JWSInvalid(f"payload missing required fields: {exc}") from exc

        if tx.bundle_id != self._app_bundle_id:
            raise JWSWrongBundle(
                f"bundle mismatch: JWS bundleId={tx.bundle_id!r}, "
                f"expected {self._app_bundle_id!r}"
            )
        if tx.environment != self._environment:
            raise JWSInvalid(
                f"environment mismatch: JWS environment={tx.environment!r}, "
                f"expected {self._environment!r}"
            )
        if tx.expires_date is not None and tx.expires_date < now:
            raise JWSExpired(
                f"transaction {tx.transaction_id} expired at {tx.expires_date.isoformat()}"
            )
        return tx

    @staticmethod
    def _parse_header(header_b64: str) -> dict:
        try:
            header = json.loads(_b64url_decode(header_b64))
        except json.JSONDecodeError as exc:
            raise JWSInvalid(f"header is not valid JSON: {exc}") from exc
        if not isinstance(header, dict):
            raise JWSInvalid("header must be a JSON object")
        if header.get("alg") != "ES256":
            raise JWSInvalid(f"unsupported alg={header.get('alg')!r}; expected ES256")
        return header

    @staticmethod
    def _parse_chain(x5c: Optional[list]) -> list[x509.Certificate]:
        if not isinstance(x5c, list) or not (1 <= len(x5c) <= _MAX_CHAIN_LEN):
            raise JWSInvalid(
                f"x5c must be a 1..{_MAX_CHAIN_LEN} length list of base64 certs"
            )
        chain: list[x509.Certificate] = []
        for i, entry in enumerate(x5c):
            if not isinstance(entry, str):
                raise JWSInvalid(f"x5c[{i}] is not a string")
            try:
                der = base64.b64decode(entry, validate=True)
                chain.append(x509.load_der_x509_certificate(der))
            except (ValueError, TypeError) as exc:
                raise JWSInvalid(f"x5c[{i}] is not a valid DER cert: {exc}") from exc
        return chain

    def _verify_chain(self, chain: list[x509.Certificate], now: datetime) -> None:
        for cert in chain:
            if cert.not_valid_before_utc > now:
                raise JWSInvalid(
                    f"cert not yet valid: {cert.subject.rfc4514_string()}"
                )
            if cert.not_valid_after_utc < now:
                raise JWSInvalid(
                    f"cert expired: {cert.subject.rfc4514_string()}"
                )
        for i in range(len(chain) - 1):
            self._verify_signed_by(chain[i], chain[i + 1])

        last = chain[-1]
        last_der = last.public_bytes(
            encoding=serialization.Encoding.DER
        )
        if last_der != self._root_der:
            self._verify_signed_by(last, self._root)

        if self._root.not_valid_before_utc > now or self._root.not_valid_after_utc < now:
            raise JWSInvalid("configured trust anchor is not currently valid")

    @staticmethod
    def _verify_signed_by(cert: x509.Certificate, issuer: x509.Certificate) -> None:
        if cert.issuer != issuer.subject:
            raise JWSInvalid(
                f"chain mismatch: {cert.subject.rfc4514_string()} "
                f"issuer != {issuer.subject.rfc4514_string()} subject"
            )
        issuer_key = issuer.public_key()
        if not isinstance(issuer_key, ec.EllipticCurvePublicKey):
            raise JWSInvalid("only EC issuer keys supported (Apple StoreKit uses ECDSA)")
        try:
            issuer_key.verify(
                cert.signature,
                cert.tbs_certificate_bytes,
                ec.ECDSA(cert.signature_hash_algorithm),
            )
        except InvalidSignature as exc:
            raise JWSInvalid(
                f"chain verify failed at {cert.subject.rfc4514_string()}: {exc}"
            ) from exc

    @staticmethod
    def _verify_jws_signature(
        leaf: x509.Certificate,
        header_b64: str,
        payload_b64: str,
        signature_b64: str,
    ) -> None:
        leaf_key = leaf.public_key()
        if not isinstance(leaf_key, ec.EllipticCurvePublicKey):
            raise JWSInvalid("leaf cert public key is not EC")
        if not isinstance(leaf_key.curve, ec.SECP256R1):
            raise JWSInvalid(
                f"leaf cert curve is {leaf_key.curve.name}, expected secp256r1 for ES256"
            )
        raw_sig = _b64url_decode(signature_b64)
        if len(raw_sig) != 64:
            raise JWSInvalid(f"ES256 signature must be 64 bytes, got {len(raw_sig)}")
        r = int.from_bytes(raw_sig[:32], "big")
        s = int.from_bytes(raw_sig[32:], "big")
        der_sig = encode_dss_signature(r, s)
        signing_input = f"{header_b64}.{payload_b64}".encode("ascii")
        try:
            leaf_key.verify(der_sig, signing_input, ec.ECDSA(hashes.SHA256()))
        except InvalidSignature as exc:
            raise JWSInvalid(f"signature verification failed: {exc}") from exc
