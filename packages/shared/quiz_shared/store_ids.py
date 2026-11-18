"""App identifiers and store product IDs shared by both services (#234).

Two iOS apps talk to one backend: the App Store app (``com.missinghue.hangs``)
and the TestFlight-only "Trubbo Beta" (``com.missinghue.hangs.beta``). Apple
product IDs are unique across the whole developer account, so the beta app
sells the same catalog under ``beta.`` + the live ID (``beta.pack_30``).

Everything past the store boundary (product table, ``PACK_PRODUCTS``, pack
tiers, analytics) works with the live ID only. ``canonical_product_id`` is the
one place that maps a beta ID back, and it does so ONLY for a purchase that
provably came from the beta app, so a ``beta.`` ID can never be credited under
the live app.
"""

from __future__ import annotations

from typing import Optional

LIVE_BUNDLE_ID = "com.missinghue.hangs"
BETA_BUNDLE_ID = "com.missinghue.hangs.beta"
BETA_PRODUCT_PREFIX = "beta."


def parse_id_list(raw: Optional[str]) -> tuple[str, ...]:
    """A comma-separated env value as an ordered, de-duplicated tuple.

    The first entry is the primary one (the App Store app); a single value
    parses to a one-element tuple, i.e. exactly the pre-#234 configuration.
    """
    if not raw:
        return ()
    ids: list[str] = []
    for token in raw.split(","):
        value = token.strip()
        if value and value not in ids:
            ids.append(value)
    return tuple(ids)


def canonical_product_id(bundle_id: Optional[str], product_id: str) -> str:
    """The live catalog ID for a product bought in the app ``bundle_id``.

    Strips the ``beta.`` prefix only when the purchase came from the beta
    bundle. Any other bundle gets the ID back unchanged, so a ``beta.`` ID
    arriving from the live app stays unknown to every catalog and credits
    nothing.
    """
    if bundle_id == BETA_BUNDLE_ID and product_id.startswith(BETA_PRODUCT_PREFIX):
        return product_id[len(BETA_PRODUCT_PREFIX) :]
    return product_id


def canonical_rc_product_id(
    product_id: Optional[str], environment: Optional[str]
) -> Optional[str]:
    """``canonical_product_id`` for a RevenueCat payload, which names no bundle.

    RevenueCat webhook events and the v1 ``GET /subscribers`` snapshot carry the
    store environment but not the app's bundle id. The beta app is never
    released, so every one of its purchases is Sandbox: a ``beta.`` ID is mapped
    back only on a Sandbox entry. A ``beta.`` ID claiming Production stays
    unknown and credits nothing.
    """
    if not product_id:
        return product_id
    if (environment or "").upper() == "SANDBOX":
        return canonical_product_id(BETA_BUNDLE_ID, product_id)
    return product_id
