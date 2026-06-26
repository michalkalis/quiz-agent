"""Tests for App Attest verification (issue #60 Part B, task 60.11).

Real attestations come from a device's Secure Enclave and cannot be produced on
CI, so these build *synthetic* attestations/assertions signed by a throwaway
test root CA (passed to the verifier in place of Apple's pinned root) — the same
technique pyattest's own factory uses. That exercises the full verifier wiring;
real-device end-to-end stays `[HUMAN]` (issue-60 Part B acceptance).

What matters here is the security contract: a tampered/foreign-app/wrong-env
attestation is rejected, a spent challenge can't back a second verification, and
— the guard pyattest does *not* give us — an assertion whose counter does not
strictly advance is rejected (replay), with the stored counter only moving
forward.
"""

from __future__ import annotations

import base64
import datetime
import hashlib
import struct

import pytest
from asn1crypto import keys as asn1keys
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.ec import ECDSA
from cryptography.x509.extensions import UnrecognizedExtension
from cryptography.x509.oid import NameOID, ObjectIdentifier
from cbor2 import dumps as cbor_encode
from sqlalchemy import select

from app.auth.app_attest import AppAttestError, AppAttestService
from app.auth.attest_challenge import ChallengeStore
from app.db.models import AppAttestKey

pytestmark = pytest.mark.asyncio

APP_ID = "ABCDE12345.com.example.hangs"
_NONCE_OID = "1.2.840.113635.100.8.2"
_DEV_AAGUID = b"appattestdevelop"
_PROD_AAGUID = b"appattest\x00\x00\x00\x00\x00\x00\x00"


# ── Synthetic fixture builders ───────────────────────────────────────────────


def _validity():
    before = datetime.datetime(2020, 1, 1)
    after = datetime.datetime(2035, 1, 1)
    return before, after


def _build_root() -> tuple[ec.EllipticCurvePrivateKey, x509.Certificate, bytes]:
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name(
        [x509.NameAttribute(NameOID.ORGANIZATION_NAME, "test-attest-root")]
    )
    before, after = _validity()
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(before)
        .not_valid_after(after)
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=False,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=True,
                crl_sign=True,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .sign(key, hashes.SHA256())
    )
    pem = cert.public_bytes(serialization.Encoding.PEM)
    return key, cert, pem


def _key_id_bytes(pub: ec.EllipticCurvePublicKey) -> bytes:
    spki = pub.public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    return asn1keys.PublicKeyInfo.load(spki).sha256  # == asn1 cert.public_key.sha256


def build_attestation(
    challenge: str,
    root_key,
    root_cert,
    *,
    app_id: str = APP_ID,
    aaguid: bytes = _DEV_AAGUID,
    counter: int = 0,
):
    """Return (attestation_bytes, key_id_b64, leaf_private_key) for a key that
    attests over `challenge`, signed by the given test root."""
    leaf_key = ec.generate_private_key(ec.SECP256R1())
    pub = leaf_key.public_key()
    cred_id = _key_id_bytes(pub)

    auth_data = (
        hashlib.sha256(app_id.encode()).digest()
        + b"\x00"
        + struct.pack("!I", counter)
        + aaguid
        + struct.pack("!H", len(cred_id))
        + cred_id
    )
    calc_nonce = hashlib.sha256(
        auth_data + hashlib.sha256(challenge.encode()).digest()
    ).digest()
    der_nonce = bytes(6) + calc_nonce  # pyattest strips the 6-byte ASN.1 wrapper

    before, after = _validity()
    leaf = (
        x509.CertificateBuilder()
        .subject_name(
            x509.Name([x509.NameAttribute(NameOID.ORGANIZATION_NAME, "test-leaf")])
        )
        .issuer_name(root_cert.subject)
        .public_key(pub)
        .serial_number(x509.random_serial_number())
        .not_valid_before(before)
        .not_valid_after(after)
        .add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=False,
                crl_sign=False,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=False,
        )
        .add_extension(
            UnrecognizedExtension(ObjectIdentifier(_NONCE_OID), der_nonce),
            critical=False,
        )
        .sign(root_key, hashes.SHA256())
    )

    data = {
        "fmt": "apple-appattest",
        "attStmt": {
            "x5c": [
                leaf.public_bytes(serialization.Encoding.DER),
                root_cert.public_bytes(serialization.Encoding.DER),
            ],
            "receipt": b"",
        },
        "authData": auth_data,
    }
    return cbor_encode(data), base64.b64encode(cred_id).decode(), leaf_key


def build_assertion(challenge: str, leaf_key, *, counter: int, app_id: str = APP_ID):
    """Return assertion_bytes signed by `leaf_key` carrying `counter`."""
    auth_data = (
        hashlib.sha256(app_id.encode()).digest() + b"\x00" + struct.pack("!I", counter)
    )
    client_data_hash = hashlib.sha256(challenge.encode()).digest()
    nonce = hashlib.sha256(auth_data + client_data_hash).digest()
    signature = leaf_key.sign(nonce, ECDSA(hashes.SHA256()))
    return cbor_encode({"signature": signature, "authenticatorData": auth_data})


# ── Fixtures ─────────────────────────────────────────────────────────────────


@pytest.fixture(scope="module")
def root():
    return _build_root()  # (key, cert, pem)


def _service(
    db_sessionmaker, root_pem, *, production=False, environment=None, app_id=APP_ID
):
    store = ChallengeStore(db_sessionmaker, ttl_seconds=300)
    if environment is None:
        environment = "production" if production else "development"
    return AppAttestService(
        db_sessionmaker,
        store,
        app_id=app_id,
        environment=environment,
        root_ca=root_pem,
    ), store


# ── Attestation ──────────────────────────────────────────────────────────────


async def test_attestation_verifies_and_stores_key(db_sessionmaker, root):
    root_key, root_cert, root_pem = root
    svc, store = _service(db_sessionmaker, root_pem)
    challenge = await store.issue()
    attestation, key_id_b64, _ = build_attestation(challenge, root_key, root_cert)

    # Attestation runs on first launch, before an identity is minted, so the key
    # is stored unbound; bootstrap binds anon_id later (60.12).
    row = await svc.verify_attestation(key_id_b64, attestation, challenge)

    assert row.key_id == key_id_b64
    assert row.sign_counter == 0
    assert row.environment == "development"
    assert row.anon_id is None
    async with db_sessionmaker() as s:
        stored = (
            await s.execute(
                select(AppAttestKey).where(AppAttestKey.key_id == key_id_b64)
            )
        ).scalar_one()
    assert stored.public_key  # DER SPKI persisted for later assertions


async def test_attestation_rejected_when_challenge_spent(db_sessionmaker, root):
    root_key, root_cert, root_pem = root
    svc, store = _service(db_sessionmaker, root_pem)
    challenge = await store.issue()
    attestation, key_id_b64, _ = build_attestation(challenge, root_key, root_cert)

    await store.consume(challenge)  # challenge already spent elsewhere
    with pytest.raises(AppAttestError):
        await svc.verify_attestation(key_id_b64, attestation, challenge)


async def test_attestation_rejected_for_foreign_app_id(db_sessionmaker, root):
    """An attestation produced for a different app must not verify — this is the
    rpId binding that stops another app's attestations being replayed at us."""
    root_key, root_cert, root_pem = root
    svc, store = _service(db_sessionmaker, root_pem, app_id=APP_ID)
    challenge = await store.issue()
    attestation, key_id_b64, _ = build_attestation(
        challenge, root_key, root_cert, app_id="OTHER999.com.evil.app"
    )
    with pytest.raises(AppAttestError):
        await svc.verify_attestation(key_id_b64, attestation, challenge)


async def test_attestation_rejected_for_wrong_environment(db_sessionmaker, root):
    """A development-attested key must not be honoured by a production verifier
    (the aaguid environment gotcha)."""
    root_key, root_cert, root_pem = root
    svc, store = _service(db_sessionmaker, root_pem, production=True)
    challenge = await store.issue()
    attestation, key_id_b64, _ = build_attestation(
        challenge, root_key, root_cert, aaguid=_DEV_AAGUID
    )
    with pytest.raises(AppAttestError):
        await svc.verify_attestation(key_id_b64, attestation, challenge)


async def test_attestation_accepts_both_environments_when_configured(
    db_sessionmaker, root
):
    """With ``environment='both'`` one backend honours both a development-aaguid
    build (Xcode→device) and a production-aaguid build (TestFlight/App Store) —
    and records which environment each key actually used. This is the
    no-flag-flipping mode for serving dev + prod builds off one backend."""
    root_key, root_cert, root_pem = root
    svc, store = _service(db_sessionmaker, root_pem, environment="both")

    c_dev = await store.issue()
    att_dev, kid_dev, _ = build_attestation(
        c_dev, root_key, root_cert, aaguid=_DEV_AAGUID
    )
    row_dev = await svc.verify_attestation(kid_dev, att_dev, c_dev)
    assert row_dev.environment == "development"

    c_prod = await store.issue()
    att_prod, kid_prod, _ = build_attestation(
        c_prod, root_key, root_cert, aaguid=_PROD_AAGUID
    )
    row_prod = await svc.verify_attestation(kid_prod, att_prod, c_prod)
    assert row_prod.environment == "production"


async def test_attestation_rejected_for_untrusted_root(db_sessionmaker, root):
    """An attestation signed by a root the server does not trust is rejected —
    the cert-chain pin is what binds the key to Apple."""
    root_key, root_cert, _ = root
    other_key, other_cert, other_pem = _build_root()
    # Verifier trusts `other` root, but the attestation is signed by `root`.
    svc, store = _service(db_sessionmaker, other_pem)
    challenge = await store.issue()
    attestation, key_id_b64, _ = build_attestation(challenge, root_key, root_cert)
    with pytest.raises(AppAttestError):
        await svc.verify_attestation(key_id_b64, attestation, challenge)


# ── Assertion ────────────────────────────────────────────────────────────────


async def _attest(svc, store, root_key, root_cert):
    challenge = await store.issue()
    attestation, key_id_b64, leaf_key = build_attestation(
        challenge, root_key, root_cert
    )
    await svc.verify_attestation(key_id_b64, attestation, challenge)
    return key_id_b64, leaf_key


async def test_assertion_verifies_and_advances_counter(db_sessionmaker, root):
    root_key, root_cert, root_pem = root
    svc, store = _service(db_sessionmaker, root_pem)
    key_id_b64, leaf_key = await _attest(svc, store, root_key, root_cert)

    challenge = await store.issue()
    assertion = build_assertion(challenge, leaf_key, counter=5)
    row = await svc.verify_assertion(key_id_b64, assertion, challenge)

    assert row.sign_counter == 5  # advanced from the stored 0


async def test_assertion_replay_rejected_when_counter_not_advanced(
    db_sessionmaker, root
):
    """The replay guard pyattest does not provide: an assertion whose counter
    does not strictly exceed the stored value is rejected, and the stored
    counter does not move."""
    root_key, root_cert, root_pem = root
    svc, store = _service(db_sessionmaker, root_pem)
    key_id_b64, leaf_key = await _attest(svc, store, root_key, root_cert)

    # Advance to 5.
    c1 = await store.issue()
    await svc.verify_assertion(key_id_b64, build_assertion(c1, leaf_key, counter=5), c1)

    # Replay at the same counter → rejected.
    c2 = await store.issue()
    with pytest.raises(AppAttestError):
        await svc.verify_assertion(
            key_id_b64, build_assertion(c2, leaf_key, counter=5), c2
        )

    async with db_sessionmaker() as s:
        row = (
            await s.execute(
                select(AppAttestKey).where(AppAttestKey.key_id == key_id_b64)
            )
        ).scalar_one()
    assert row.sign_counter == 5  # unchanged by the rejected replay


async def test_assertion_rejected_for_unknown_key(db_sessionmaker, root):
    _, _, root_pem = root
    svc, store = _service(db_sessionmaker, root_pem)
    leaf_key = ec.generate_private_key(ec.SECP256R1())
    challenge = await store.issue()
    assertion = build_assertion(challenge, leaf_key, counter=1)
    with pytest.raises(AppAttestError):
        await svc.verify_assertion("unknown-key-id", assertion, challenge)


async def test_assertion_rejected_for_bad_signature(db_sessionmaker, root):
    """A valid stored key, but the assertion is signed by a different key."""
    root_key, root_cert, root_pem = root
    svc, store = _service(db_sessionmaker, root_pem)
    key_id_b64, _ = await _attest(svc, store, root_key, root_cert)

    impostor = ec.generate_private_key(ec.SECP256R1())
    challenge = await store.issue()
    assertion = build_assertion(challenge, impostor, counter=9)
    with pytest.raises(AppAttestError):
        await svc.verify_assertion(key_id_b64, assertion, challenge)


async def test_assertion_rejected_for_rpid_mismatch(db_sessionmaker, root):
    """An assertion whose authData rpIdHash is for a different app is rejected."""
    root_key, root_cert, root_pem = root
    svc, store = _service(db_sessionmaker, root_pem)
    key_id_b64, leaf_key = await _attest(svc, store, root_key, root_cert)

    challenge = await store.issue()
    # Signed correctly by the right key, but over a foreign app's rpId.
    assertion = build_assertion(
        challenge, leaf_key, counter=3, app_id="OTHER999.com.evil.app"
    )
    with pytest.raises(AppAttestError):
        await svc.verify_assertion(key_id_b64, assertion, challenge)


async def test_assertion_challenge_is_single_use(db_sessionmaker, root):
    root_key, root_cert, root_pem = root
    svc, store = _service(db_sessionmaker, root_pem)
    key_id_b64, leaf_key = await _attest(svc, store, root_key, root_cert)

    challenge = await store.issue()
    await svc.verify_assertion(
        key_id_b64, build_assertion(challenge, leaf_key, counter=2), challenge
    )
    # Same challenge, fresh (higher-counter) assertion → still rejected: spent.
    with pytest.raises(AppAttestError):
        await svc.verify_assertion(
            key_id_b64, build_assertion(challenge, leaf_key, counter=3), challenge
        )
