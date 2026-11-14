"""Trubbo Beta next to the App Store app (#234).

The beta app (`com.missinghue.hangs.beta`) sells the same catalog under
`beta.`-prefixed product IDs, because Apple product IDs are unique across the
developer account. What must hold:

- a beta purchase is credited exactly like the live product it mirrors, so the
  founder can test the full purchase flow in the beta;
- a `beta.` ID never buys anything under the live app (the prefix mapping is
  tied to the beta bundle, not to the string);
- an app that is not ours is still refused, two configured bundles must not
  turn the bundle check into allow-all;
- a single configured bundle behaves exactly as before #234, so the deploy is
  safe before the prod env value changes.
"""

from __future__ import annotations

import pytest

from app.api.v1.orders import _PRODUCT_TIERS
from app.config import Settings
from app.storekit import AppleJWSVerifier, JWSWrongBundle
from app.storekit.notifications import decode_notification
from app.storekit.reconcile import PACK_PRODUCTS, pack_transactions_since, server_api_clients
from app.storekit.server_api import make_token
from quiz_shared.store_ids import (
    canonical_product_id,
    canonical_rc_product_id,
    parse_id_list,
)

LIVE = "com.missinghue.hangs"
BETA = "com.missinghue.hangs.beta"
BOTH = f"{LIVE},{BETA}"


@pytest.fixture
def two_apps(test_chain) -> AppleJWSVerifier:
    """The prod config after #234: `APP_BUNDLE_ID=<live>,<beta>`."""
    return AppleJWSVerifier(test_chain.root_cert, BOTH, ("Production", "Sandbox"))


@pytest.fixture
def live_only(test_chain) -> AppleJWSVerifier:
    """The prod config before #234 (and the default)."""
    return AppleJWSVerifier(test_chain.root_cert, LIVE, ("Production", "Sandbox"))


def _jws(make_jws, bundle: str, product: str, tx_id: str = "3000000000000001") -> str:
    return make_jws(
        payload_overrides={
            "bundleId": bundle,
            "productId": product,
            "transactionId": tx_id,
            "originalTransactionId": tx_id,
        }
    )


def test_beta_pack_purchase_is_credited_as_the_live_pack(two_apps, make_jws):
    # Everything downstream (pack tiers, reconcile, revocation) keys on the
    # live id; a beta purchase that came back as `beta.pack_30` would be
    # charged in sandbox and then refused as an unknown product.
    tx = two_apps.verify(_jws(make_jws, BETA, "beta.pack_30"))
    assert tx.bundle_id == BETA
    assert tx.product_id == "pack_30"
    assert _PRODUCT_TIERS[tx.product_id] == 30


def test_beta_product_id_on_the_live_bundle_buys_nothing(two_apps, make_jws):
    # The prefix is stripped because the purchase came from the beta app, not
    # because the string starts with `beta.`; under the live app it stays an
    # id no catalog knows.
    tx = two_apps.verify(_jws(make_jws, LIVE, "beta.pack_30"))
    assert tx.product_id == "beta.pack_30"
    assert tx.product_id not in _PRODUCT_TIERS
    assert tx.product_id not in PACK_PRODUCTS


def test_live_purchase_is_untouched(two_apps, make_jws):
    assert two_apps.verify(_jws(make_jws, LIVE, "pack_30")).product_id == "pack_30"


def test_unknown_bundle_is_still_rejected_with_two_apps_configured(two_apps, make_jws):
    with pytest.raises(JWSWrongBundle):
        two_apps.verify(_jws(make_jws, "com.example.other", "pack_30"))
    with pytest.raises(JWSWrongBundle):
        two_apps.verify(_jws(make_jws, "com.example.other", "beta.pack_30"))


def test_single_bundle_config_rejects_the_beta_app_as_before(live_only, make_jws):
    # Until prod sets the beta bundle, a beta JWS is "a different app".
    with pytest.raises(JWSWrongBundle):
        live_only.verify(_jws(make_jws, BETA, "beta.pack_30"))
    assert live_only.verify(_jws(make_jws, LIVE, "pack_20")).product_id == "pack_20"


def test_notification_from_the_beta_app_is_accepted_only_when_configured(
    two_apps, live_only, make_jws
):
    # A refund in the beta app must revoke its order; with one bundle the
    # webhook keeps refusing other apps' notifications exactly as before.
    notification = make_jws(
        payload_overrides={
            "notificationType": "REFUND",
            "data": {"bundleId": BETA, "environment": "Sandbox"},
        }
    )
    assert decode_notification(notification, two_apps).notification_type == "REFUND"
    with pytest.raises(JWSWrongBundle):
        decode_notification(notification, live_only)


def test_refunded_beta_transaction_is_recorded_under_the_live_id(two_apps, make_jws):
    # record_revocation stores `tx.product_id`; the inner REFUND transaction
    # goes through verify_transaction_info, which must canonicalize too.
    tx = two_apps.verify_transaction_info(
        make_jws(
            payload_overrides={
                "bundleId": BETA,
                "productId": "beta.pack_10",
                "revocationDate": 1_700_000_000_000,
                "revocationReason": 1,
            }
        )
    )
    assert tx.product_id == "pack_10"


def test_reconcile_counts_a_lost_beta_pack_order(two_apps, make_jws):
    # After a DB restore a beta order must be found like any other.
    from datetime import datetime, timezone

    jws = _jws(make_jws, BETA, "beta.pack_30", tx_id="3000000000000009")
    found = pack_transactions_since(
        ["3000000000000009"],
        datetime(2026, 1, 1, tzinfo=timezone.utc),
        lambda _seed: [jws],
        two_apps,
    )
    assert found["3000000000000009"].product_id == "pack_30"


def test_reconcile_asks_apple_once_per_app(monkeypatch):
    # The Server API token's `bid` scopes every call to one app: a beta
    # customer's history is only reachable with a beta-bundle token.
    import base64
    import json

    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec

    pem = (
        ec.generate_private_key(ec.SECP256R1())
        .private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
        .decode()
    )
    settings = Settings(
        app_bundle_id=BOTH,
        storekit_environment="Production,Sandbox",
        app_store_server_key_id="KEY",
        app_store_server_issuer_id="issuer",
        app_store_server_private_key=pem,
    )
    clients = server_api_clients(settings)

    def bid(client) -> str:
        payload = make_token(client._creds).split(".")[1]
        return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))["bid"]

    assert [(bid(c), c.environment) for c in clients] == [
        (LIVE, "Production"),
        (LIVE, "Sandbox"),
        (BETA, "Production"),
        (BETA, "Sandbox"),
    ]

    single = server_api_clients(settings.model_copy(update={"app_bundle_id": LIVE}))
    assert [bid(c) for c in single] == [LIVE, LIVE]


def test_app_bundle_id_env_is_a_list_with_the_store_app_first(monkeypatch):
    monkeypatch.setenv("APP_BUNDLE_ID", f" {LIVE} , {BETA} ")
    assert Settings(_env_file=None).app_bundle_ids == (LIVE, BETA)
    monkeypatch.delenv("APP_BUNDLE_ID")
    assert Settings(_env_file=None).app_bundle_ids == (LIVE,)


def test_shared_helpers_map_only_provable_beta_purchases():
    assert parse_id_list(f"{LIVE},,{LIVE}") == (LIVE,)
    assert canonical_product_id(BETA, "beta.com.carquiz.unlimited.monthly") == (
        "com.carquiz.unlimited.monthly"
    )
    assert canonical_product_id(BETA, "pack_30") == "pack_30"
    assert canonical_product_id(LIVE, "beta.pack_30") == "beta.pack_30"
    assert canonical_product_id(None, "beta.pack_30") == "beta.pack_30"
    # RevenueCat names no bundle: only a Sandbox purchase can be a beta one.
    assert canonical_rc_product_id("beta.pack_30", "SANDBOX") == "pack_30"
    assert canonical_rc_product_id("beta.pack_30", "PRODUCTION") == "beta.pack_30"
    assert canonical_rc_product_id("beta.pack_30", None) == "beta.pack_30"
