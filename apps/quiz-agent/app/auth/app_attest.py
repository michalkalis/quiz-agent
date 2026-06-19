"""App Attest verification — attestation (first install) + assertion (ongoing).

Issue #60 Part B, task 60.11. This is the lock that makes a self-issued anonymous
token hard to forge: it proves a request comes from *our* genuine app on a *real*
iPhone (Secure Enclave), not a script minting unlimited identities.

Two halves, deliberately split by trust surface (see the pyattest audit in
``docs/issues/issue-60``):

- **Attestation** runs through ``pyattest`` 1.0.4, whose attestation path is
  complete and tested: cert chain → pinned Apple root, nonce, keyId, rpId,
  ``counter == 0``, aaguid/environment. We add nothing to it but storage.
- **Assertion** is implemented *here* with ``cbor2`` + ``cryptography``, on
  purpose: pyattest's assertion verifier only checks the signature (its own test
  is skipped) and the replay guard — *counter strictly greater than the value we
  stored* — can only live next to that stored value, inside one DB transaction.
  We additionally re-check the rpId. Doing it directly keeps the security-
  critical path short and auditable.

Every verification first **consumes a single-use challenge**: a captured
attestation/assertion is worthless because its challenge can never be spent twice.
"""

from __future__ import annotations

import base64
import hashlib
import struct
from datetime import datetime, timezone

from cbor2 import loads as cbor_decode
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ec import ECDSA
from cryptography.hazmat.primitives.hashes import SHA256
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from ..db.models import AppAttestKey
from .attest_challenge import ChallengeError, ChallengeStore


def _now() -> datetime:
    return datetime.now(timezone.utc)


class AppAttestError(Exception):
    """An attestation or assertion failed verification. The caller maps this to a
    rejected request (HTTP 401) — never leak which specific step failed."""


class AppAttestService:
    def __init__(
        self,
        sessionmaker: async_sessionmaker[AsyncSession],
        challenge_store: ChallengeStore,
        *,
        app_id: str,
        production: bool,
        root_ca: bytes | None = None,
    ) -> None:
        if not app_id:
            raise RuntimeError("APP_ATTEST_APP_ID must be set to verify App Attest.")
        self._sessionmaker = sessionmaker
        self._challenges = challenge_store
        self._app_id = app_id
        self._production = production
        self._root_ca = root_ca  # None → pyattest's bundled, pinned Apple root CA
        self._environment = "production" if production else "development"

    # ── Attestation (first install) ─────────────────────────────────────────

    async def verify_attestation(
        self,
        key_id_b64: str,
        attestation: bytes,
        challenge: str,
        *,
        anon_id: str | None = None,
        session: AsyncSession | None = None,
    ) -> AppAttestKey:
        """Verify a first-install attestation and persist the attested key.

        The challenge is spent first (single-use). pyattest then performs the
        full Apple attestation check against ``key_id`` (the keyId the client
        reported); on success we store the key with ``sign_counter = 0`` so the
        first assertion must report a strictly greater counter.

        When ``session`` is supplied the key is added to *that* transaction and
        **not** committed — the caller owns the commit. ``anon-bootstrap`` uses
        this to mint the identity, bind the key, and issue the first refresh
        token atomically, so a crash can never leave an attested-but-unbound key
        next to a token-bearing identity (#60.12). With no ``session`` the method
        opens and commits its own (standalone verification, used by tests).
        """
        # Lazy import: pyattest pulls a cert-validation stack we only need here.
        from pyattest.attestation import Attestation
        from pyattest.configs.apple import AppleConfig
        from pyattest.exceptions import PyAttestException

        await self._consume(challenge)

        try:
            key_id = base64.b64decode(key_id_b64)
        except Exception as exc:  # malformed keyId from the client
            raise AppAttestError("invalid key id") from exc

        config = AppleConfig(
            key_id=key_id,
            app_id=self._app_id,
            production=self._production,
            root_ca=self._root_ca,
        )
        attest = Attestation(attestation, challenge.encode(), config)
        try:
            await attest.verify()
        except PyAttestException as exc:
            raise AppAttestError("attestation failed verification") from exc

        # The verified leaf cert's public key, stored as DER SPKI so an assertion
        # can later reload it with cryptography.load_der_public_key.
        leaf = attest.data["certs"].last
        public_key_der = leaf.public_key.dump()

        key = AppAttestKey(
            key_id=key_id_b64,
            anon_id=anon_id,
            public_key=public_key_der,
            sign_counter=0,
            environment=self._environment,
            created_at=_now(),
        )

        if session is not None:
            # Join the caller's transaction; they commit. flush() surfaces a
            # duplicate-key conflict here rather than at their later commit.
            session.add(key)
            await session.flush()
            return key

        async with self._sessionmaker() as own_session:
            own_session.add(key)
            await own_session.commit()
            return await own_session.get(AppAttestKey, key_id_b64)

    # ── Assertion (ongoing) ─────────────────────────────────────────────────

    async def verify_assertion(
        self, key_id_b64: str, assertion: bytes, challenge: str
    ) -> AppAttestKey:
        """Verify an ongoing assertion against the stored key and advance the
        counter. Raises ``AppAttestError`` on any failure.

        Steps pyattest does **not** do for us (audit): the counter must be
        strictly greater than the stored value (replay guard) and the rpId must
        match — both checked here, with the counter advanced transactionally
        under a row lock so two concurrent assertions can't both pass on the
        same counter.
        """
        await self._consume(challenge)

        signature, authenticator_data, counter = self._unpack_assertion(assertion)

        async with self._sessionmaker() as session:
            row = (
                await session.execute(
                    select(AppAttestKey)
                    .where(AppAttestKey.key_id == key_id_b64)
                    .with_for_update()
                )
            ).scalar_one_or_none()
            if row is None:
                raise AppAttestError("unknown attest key")

            # rpId: the first 32 bytes of authData are SHA-256(app_id).
            if (
                authenticator_data[:32]
                != hashlib.sha256(self._app_id.encode()).digest()
            ):
                raise AppAttestError("rpId mismatch")

            # Signature over SHA-256(authData ‖ SHA-256(challenge)).
            client_data_hash = hashlib.sha256(challenge.encode()).digest()
            nonce = hashlib.sha256(authenticator_data + client_data_hash).digest()
            public_key = serialization.load_der_public_key(row.public_key)
            try:
                public_key.verify(signature, nonce, ECDSA(SHA256()))
            except InvalidSignature as exc:
                raise AppAttestError("assertion signature invalid") from exc

            # Replay guard: strictly increasing counter, then persist it.
            if counter <= row.sign_counter:
                raise AppAttestError("assertion counter did not advance")
            row.sign_counter = counter
            await session.commit()
            await session.refresh(row)
            return row

    @staticmethod
    def _unpack_assertion(assertion: bytes) -> tuple[bytes, bytes, int]:
        """Decode the CBOR assertion into (signature, authenticatorData, counter)."""
        try:
            raw = cbor_decode(assertion)
            authenticator_data = raw["authenticatorData"]
            counter = struct.unpack("!I", authenticator_data[33:37])[0]
            return raw["signature"], authenticator_data, counter
        except Exception as exc:  # any CBOR/shape failure → reject as malformed
            raise AppAttestError("malformed assertion") from exc

    async def _consume(self, challenge: str) -> None:
        try:
            await self._challenges.consume(challenge)
        except ChallengeError as exc:
            raise AppAttestError("invalid or spent challenge") from exc


def build_app_attest_service(
    sessionmaker: async_sessionmaker[AsyncSession],
    challenge_store: ChallengeStore,
    settings,
) -> AppAttestService:
    return AppAttestService(
        sessionmaker,
        challenge_store,
        app_id=settings.app_attest_app_id,
        production=settings.app_attest_production,
    )
