"""Pure subscription-state math for issue #93 (subscription IAP + packs).

This module is the single home for the entitlement concurrency rules described
in Design §1 / §4 of ``docs/issues/issue-93-subscription-iap-packs.md``. The
webhook path (Session C), the ``/entitlements/sync`` path, and the anon->sign-in
fold (Session D) all import these functions instead of re-embedding the logic.

Hard invariant: **no DB, no network, no imports from ``app.db``.** Every function
takes and returns plain state values (dataclasses) so it is trivially unit-testable
and re-usable from any caller.

Two decisions are implemented here verbatim (do not re-litigate):

* **D-order (extend/revoke split + watermark).** A pure max-wins-on-``expires_at``
  guard structurally *cannot* apply a revoke (a refund moves expiry backward, or
  ties with status->expired — both dropped by max-wins), which would let a
  refunded annual sub keep unlimited for ~11 months. So events are classified:
  *extend* events push expiry forward (max-wins, status precedence on ties);
  *revoke* events **write** the (possibly earlier) ``expires_at`` / ``expired``
  status. Both are ordered by the per-event watermark ``last_event_ts_ms``: an
  event applies iff its timestamp is **strictly newer** than the stored
  watermark (NULL watermark => first event applies).

* **D-merge (anon->sign-in fold).** The fold resolves two rows for one account
  **row-wise**: the winner is the whole row with the greater ``expires_at`` taken
  as one unit (its status comes with it — never synthesize a ``{status,
  expires_at}`` combination neither source held). Only ``last_event_ts_ms`` is
  resolved separately, as a field-wise max.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import datetime

# --- Status model (D-grace: 'grace' counts as entitled downstream) -----------

STATUS_ACTIVE = "active"
STATUS_GRACE = "grace"
STATUS_EXPIRED = "expired"

# Higher wins on an ``expires_at`` tie (active > grace > expired).
_STATUS_PRECEDENCE = {STATUS_EXPIRED: 0, STATUS_GRACE: 1, STATUS_ACTIVE: 2}

# --- Event classification (see D-order) --------------------------------------
#
# PRODUCT_CHANGE is intentionally absent from both sets: an upgrade crossgrade is
# an *extend* and a downgrade is a *revoke*, a direction only the caller knows.
# The caller therefore supplies ``event_class`` explicitly; these constants let
# the webhook map the unambiguous RC event types via :func:`classify_event_type`.

EXTEND_EVENT_TYPES = frozenset({"INITIAL_PURCHASE", "RENEWAL", "UNCANCELLATION"})
REVOKE_EVENT_TYPES = frozenset({"REFUND", "CHARGEBACK", "CANCELLATION", "EXPIRATION"})

EVENT_CLASS_EXTEND = "extend"
EVENT_CLASS_REVOKE = "revoke"


def classify_event_type(
    event_type: str, *, product_change_is_upgrade: bool | None = None
) -> str:
    """Map an RC event type to ``'extend'`` or ``'revoke'``.

    ``PRODUCT_CHANGE`` is ambiguous by type alone, so the caller must pass
    ``product_change_is_upgrade`` (True => extend, False => revoke) for it.
    """

    if event_type in EXTEND_EVENT_TYPES:
        return EVENT_CLASS_EXTEND
    if event_type in REVOKE_EVENT_TYPES:
        return EVENT_CLASS_REVOKE
    if event_type == "PRODUCT_CHANGE":
        if product_change_is_upgrade is None:
            raise ValueError(
                "PRODUCT_CHANGE requires product_change_is_upgrade to classify"
            )
        return EVENT_CLASS_EXTEND if product_change_is_upgrade else EVENT_CLASS_REVOKE
    raise ValueError(f"unknown subscription event type: {event_type!r}")


# --- State + event shapes ----------------------------------------------------


@dataclass(frozen=True)
class SubscriptionState:
    """The one active-sub projection per account (mirror of the ``subscription``
    ORM row, without any ORM/DB coupling).

    ``last_event_ts_ms`` is the per-event ordering watermark (RC
    ``event_timestamp_ms``); ``None`` until the first event/sync applies.
    """

    product_id: str
    status: str  # active | grace | expired
    expires_at: datetime
    rc_original_txn_id: str
    last_event_ts_ms: int | None = None


@dataclass(frozen=True)
class SubscriptionEvent:
    """A single normalized RC webhook event, already mapped to helper inputs.

    ``event_class`` is authoritative (see :func:`classify_event_type`).
    ``event_ts_ms`` is RC's ``event_timestamp_ms`` used for watermark ordering.
    """

    event_class: str  # 'extend' | 'revoke'
    product_id: str
    status: str  # the status this event sets: active | grace | expired
    expires_at: datetime
    rc_original_txn_id: str
    event_ts_ms: int


def _precedence(status: str) -> int:
    return _STATUS_PRECEDENCE[status]


def _state_from_event(event: SubscriptionEvent) -> SubscriptionState:
    return SubscriptionState(
        product_id=event.product_id,
        status=event.status,
        expires_at=event.expires_at,
        rc_original_txn_id=event.rc_original_txn_id,
        last_event_ts_ms=event.event_ts_ms,
    )


# --- Core operations ---------------------------------------------------------


def apply_subscription_event(
    current: SubscriptionState | None, event: SubscriptionEvent
) -> SubscriptionState | None:
    """Fold ``event`` into ``current`` under the D-order rules.

    Watermark: the event applies iff ``event.event_ts_ms`` is **strictly newer**
    than ``current.last_event_ts_ms``. A ``None`` watermark (no current row, or a
    row that never took an event) means the event is the first to apply. A stale
    event (``event_ts_ms <= watermark``) is dropped and ``current`` is returned
    unchanged.

    On apply, the watermark advances to ``event.event_ts_ms``:

    * **extend** — max-wins on ``expires_at``; on an ``expires_at`` tie the row
      with higher status precedence (active > grace > expired) is taken wholesale.
    * **revoke** — the event's ``status`` / ``expires_at`` are written directly,
      so expiry can move backward and/or flip to ``expired``.
    """

    if current is not None and current.last_event_ts_ms is not None:
        if event.event_ts_ms <= current.last_event_ts_ms:
            return current  # stale / replayed — dropped in BOTH directions

    if current is None:
        # First event: adopt the event's state wholesale.
        return _state_from_event(event)

    if event.event_class == EVENT_CLASS_REVOKE:
        # Write the (possibly earlier) expiry / expired status. This is the whole
        # point of the split — a revoke must be able to move expiry backward.
        return _state_from_event(event)

    if event.event_class == EVENT_CLASS_EXTEND:
        if event.expires_at > current.expires_at:
            return _state_from_event(event)
        if event.expires_at < current.expires_at:
            # max-wins keeps the current (longer) expiry & its row; only the
            # watermark advances.
            return replace(current, last_event_ts_ms=event.event_ts_ms)
        # expires_at tie -> status precedence decides the whole winning row.
        if _precedence(event.status) > _precedence(current.status):
            return _state_from_event(event)
        return replace(current, last_event_ts_ms=event.event_ts_ms)

    raise ValueError(f"unknown event_class: {event.event_class!r}")


def merge_subscription_rows(
    a: SubscriptionState | None, b: SubscriptionState | None
) -> SubscriptionState | None:
    """Row-wise merge of two account rows for the anon->sign-in fold (D-merge).

    The winner is the **whole** row with the greater ``expires_at`` (its status
    comes with it — no synthesized ``{status, expires_at}`` combo). On an
    ``expires_at`` tie the higher status-precedence row wins wholesale. Only
    ``last_event_ts_ms`` is resolved separately, as a field-wise max (``None``
    treated as no watermark).
    """

    if a is None:
        return b
    if b is None:
        return a

    if a.expires_at > b.expires_at:
        winner = a
    elif b.expires_at > a.expires_at:
        winner = b
    elif _precedence(a.status) >= _precedence(b.status):
        winner = a
    else:
        winner = b

    return replace(
        winner, last_event_ts_ms=_max_ts(a.last_event_ts_ms, b.last_event_ts_ms)
    )


def _max_ts(x: int | None, y: int | None) -> int | None:
    if x is None:
        return y
    if y is None:
        return x
    return x if x >= y else y
