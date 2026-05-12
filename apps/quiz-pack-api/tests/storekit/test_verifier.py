"""Unit tests for `app.storekit.verifier` (issue #33 Task 1.8).

Each test encodes WHY the behavior matters (per CLAUDE.md rule 9), not just
WHAT it does. The chain/signing-key fixtures come from `conftest.py`; the
verifier is constructed against the test root, so we exercise the real cert
chain logic without depending on Apple's bundled root.
"""

from __future__ import annotations

import base64
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

from app.storekit import (
    AppleJWSVerifier,
    JWSInvalid,
    JWSWrongBundle,
    SignedTransaction,
)


BUNDLED_ROOT = (
    Path(__file__).resolve().parents[2]
    / "app"
    / "storekit"
    / "certs"
    / "AppleRootCA-G3.cer"
)


@pytest.fixture
def verifier(test_chain) -> AppleJWSVerifier:
    return AppleJWSVerifier(
        root_cert=test_chain.root_cert,
        app_bundle_id="com.missinghue.hangs",
        environment="Sandbox",
    )


def test_valid_sandbox_jws_returns_signed_transaction(verifier, make_jws):
    """A correctly-signed JWS for the configured bundle/env must verify.

    Encodes the contract that POST /v1/orders relies on (Task 1.9):
    verify(jws) returns the parsed payload, callers can trust the fields.
    """
    jws = make_jws()
    tx = verifier.verify(jws)
    assert isinstance(tx, SignedTransaction)
    assert tx.transaction_id == "1000000123456789"
    assert tx.product_id == "pack_20"
    assert tx.bundle_id == "com.missinghue.hangs"
    assert tx.environment == "Sandbox"
    assert tx.purchase_date.tzinfo is not None


def test_production_environment_matches_when_configured(test_chain, make_jws):
    """Per-deploy environment guard works for prod too, not just Sandbox."""
    prod_verifier = AppleJWSVerifier(
        root_cert=test_chain.root_cert,
        app_bundle_id="com.missinghue.hangs",
        environment="Production",
    )
    jws = make_jws(payload_overrides={"environment": "Production"})
    tx = prod_verifier.verify(jws)
    assert tx.environment == "Production"


def test_tampered_payload_raises_jws_invalid(verifier, make_jws):
    """Any payload byte change must invalidate the signature.

    Without this, a forged JWS could swap product_id from pack_10 → pack_50
    and entitle the user to 5× the questions.
    """
    jws = make_jws()
    header, payload, sig = jws.split(".")
    tampered_payload = bytearray(base64.urlsafe_b64decode(payload + "=="))
    tampered_payload[10] ^= 0x01
    new_payload_b64 = (
        base64.urlsafe_b64encode(bytes(tampered_payload)).rstrip(b"=").decode("ascii")
    )
    forged = f"{header}.{new_payload_b64}.{sig}"
    with pytest.raises(JWSInvalid, match="signature verification failed"):
        verifier.verify(forged)


def test_tampered_signature_raises_jws_invalid(verifier, make_jws):
    """A bit-flip in the signature itself is rejected.

    Defense in depth: even if an attacker preserved payload integrity but
    swapped the signature, we don't accept it.
    """
    jws = make_jws(tamper_signature=True)
    with pytest.raises(JWSInvalid, match="signature verification failed"):
        verifier.verify(jws)


def test_wrong_bundle_raises_jws_wrong_bundle(verifier, make_jws):
    """A JWS signed for a different app must be rejected loudly.

    Distinct exception so logs/Sentry can flag "JWS for a different app" as a
    security signal — separate from chain failures or config drift.
    """
    jws = make_jws(payload_overrides={"bundleId": "com.evil.knockoff"})
    with pytest.raises(JWSWrongBundle, match="bundle mismatch"):
        verifier.verify(jws)


def test_wrong_environment_raises_jws_invalid(verifier, make_jws):
    """Sandbox JWS hitting Production (or vice versa) is config drift, not auth.

    Phase 1 ships with separate Fly apps for sandbox/prod (per plan), so this
    error means someone misrouted a build — we want the loud failure to make
    that obvious during smoke tests.
    """
    jws = make_jws(payload_overrides={"environment": "Production"})
    with pytest.raises(JWSInvalid, match="environment mismatch"):
        verifier.verify(jws)


def test_chain_signed_by_unknown_root_raises_jws_invalid(test_chain, make_jws):
    """Verifier configured with a different root must reject chains it can't anchor.

    If we silently accepted any cert chain, the whole offline-verify promise
    is gone.
    """
    other_root_key = ec.generate_private_key(ec.SECP256R1())
    now = datetime.now(timezone.utc)
    other_root = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Wrong Root")]))
        .issuer_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Wrong Root")]))
        .public_key(other_root_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=1))
        .not_valid_after(now + timedelta(days=365))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .sign(private_key=other_root_key, algorithm=hashes.SHA256())
    )
    wrong_root_verifier = AppleJWSVerifier(
        root_cert=other_root,
        app_bundle_id="com.missinghue.hangs",
        environment="Sandbox",
    )
    jws = make_jws()
    with pytest.raises(JWSInvalid):
        wrong_root_verifier.verify(jws)


def test_missing_intermediate_breaks_chain(test_chain, make_jws, verifier):
    """If the intermediate is omitted, the leaf can't chain to the root.

    Apple sends 3-cert chains; clients/intermediaries must not strip them.
    """
    leaf_only_chain = [test_chain.chain_b64[0], test_chain.chain_b64[2]]
    jws = make_jws(chain_b64=leaf_only_chain)
    with pytest.raises(JWSInvalid):
        verifier.verify(jws)


def test_unsupported_alg_rejected(verifier, make_jws):
    """Only ES256 is in scope. HS256/none/RS256 must be rejected before any
    crypto runs — `alg=none` attacks are a classic JWT pitfall.
    """
    jws = make_jws(header_overrides={"alg": "HS256"})
    with pytest.raises(JWSInvalid, match="unsupported alg"):
        verifier.verify(jws)


def test_malformed_jws_format_rejected(verifier):
    """Any input not matching `a.b.c` shape is rejected with a clear error."""
    with pytest.raises(JWSInvalid, match="two '.' separators"):
        verifier.verify("not-a-jws")
    with pytest.raises(JWSInvalid, match="two '.' separators"):
        verifier.verify("a.b.c.d")


def test_signature_with_wrong_key_rejected(verifier, make_jws):
    """If the JWS is signed with a key not matching the leaf cert, reject.

    Covers the case where an attacker substitutes the signature from another
    valid JWS — chain looks fine, but signature doesn't bind to this payload.
    """
    rogue_key = ec.generate_private_key(ec.SECP256R1())
    jws = make_jws(signing_key=rogue_key)
    with pytest.raises(JWSInvalid, match="signature verification failed"):
        verifier.verify(jws)


def test_from_path_loads_test_root(test_chain, make_jws):
    """The classmethod loads a DER cert from disk; this is the prod codepath.

    Covers `AppleJWSVerifier.from_path` so we don't ship without a smoke test
    on the DER-loading branch.
    """
    v = AppleJWSVerifier.from_path(
        test_chain.root_cert_path,
        app_bundle_id="com.missinghue.hangs",
        environment="Sandbox",
    )
    tx = v.verify(make_jws())
    assert tx.transaction_id == "1000000123456789"


def test_from_path_missing_cert_raises_with_actionable_message(tmp_path):
    """Missing root cert must produce a clear, actionable error.

    Rule 12 (fail loud): "you forgot to fetch the cert" should be obvious from
    the error message — not a confusing chain failure 5 layers deep.
    """
    missing = tmp_path / "AppleRootCA-G3.cer"
    with pytest.raises(FileNotFoundError, match="AppleRootCA-G3"):
        AppleJWSVerifier.from_path(missing, "com.missinghue.hangs", "Sandbox")


def test_purchase_date_parses_ms_epoch(verifier, make_jws):
    """Apple sends `purchaseDate` as ms-since-epoch int, not ISO. Round-trip it."""
    iso_target = datetime(2026, 5, 12, 10, 0, tzinfo=timezone.utc)
    jws = make_jws(payload_overrides={"purchaseDate": int(iso_target.timestamp() * 1000)})
    tx = verifier.verify(jws)
    assert tx.purchase_date == iso_target


def test_payload_missing_required_field_raises(verifier, test_chain):
    """Verifier rejects a payload missing `productId` even when signature is valid.

    Encodes that we don't pass partial SignedTransactions back to callers.
    """
    import json as _json

    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

    payload = {
        "transactionId": "1000000123456789",
        "originalTransactionId": "1000000123456789",
        # productId intentionally omitted
        "bundleId": "com.missinghue.hangs",
        "purchaseDate": int(datetime(2026, 5, 12, tzinfo=timezone.utc).timestamp() * 1000),
        "environment": "Sandbox",
    }
    header = {"alg": "ES256", "x5c": list(test_chain.chain_b64)}
    h_b64 = base64.urlsafe_b64encode(
        _json.dumps(header, separators=(",", ":")).encode()
    ).rstrip(b"=").decode("ascii")
    p_b64 = base64.urlsafe_b64encode(
        _json.dumps(payload, separators=(",", ":")).encode()
    ).rstrip(b"=").decode("ascii")
    signing_input = f"{h_b64}.{p_b64}".encode("ascii")
    der_sig = test_chain.leaf_private_key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der_sig)
    raw_sig = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    s_b64 = base64.urlsafe_b64encode(raw_sig).rstrip(b"=").decode("ascii")
    jws = f"{h_b64}.{p_b64}.{s_b64}"
    with pytest.raises(JWSInvalid, match="missing required fields"):
        verifier.verify(jws)


@pytest.mark.skipif(
    not BUNDLED_ROOT.is_file(),
    reason="Run `make fetch-apple-root` from apps/quiz-pack-api/ to enable this test",
)
def test_bundled_root_validity_runway():
    """The bundled Apple root must be at least 90 days from expiry.

    This is the "rotate before it bites us" canary — when this fails in CI,
    refresh `AppleRootCA-G3.cer` (Apple G3 root is valid through 2039 today,
    so a failure is news).
    """
    data = BUNDLED_ROOT.read_bytes()
    try:
        cert = x509.load_der_x509_certificate(data)
    except ValueError:
        cert = x509.load_pem_x509_certificate(data)
    runway = cert.not_valid_after_utc - datetime.now(timezone.utc)
    assert runway > timedelta(days=90), (
        f"Bundled Apple root has only {runway.days} days runway — "
        "re-download from https://www.apple.com/certificateauthority/"
    )
