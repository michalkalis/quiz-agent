"""Unit tests for the pure subscription-state helper (issue #93, Session A).

These encode WHY each rule matters, not just what it does:
* extend uses max-wins so a real renewal extends entitlement;
* revoke can move expiry backward so a refunded annual sub loses unlimited now,
  not in ~11 months;
* the watermark drops stale/replayed events in both directions;
* the merge is row-wise so the fold never invents a status/expiry pair that
  neither device's row actually held.
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from app.usage.subscription_state import (
    EVENT_CLASS_EXTEND,
    EVENT_CLASS_REVOKE,
    STATUS_ACTIVE,
    STATUS_EXPIRED,
    STATUS_GRACE,
    SubscriptionEvent,
    SubscriptionState,
    apply_subscription_event,
    classify_event_type,
    merge_subscription_rows,
)

PID = "unlimited_monthly"
TXN = "txn_original_1"


def _dt(year: int) -> datetime:
    return datetime(year, 1, 1, tzinfo=timezone.utc)


def _state(
    *, status: str, expires: datetime, ts: int | None, product_id: str = PID
) -> SubscriptionState:
    return SubscriptionState(
        product_id=product_id,
        status=status,
        expires_at=expires,
        rc_original_txn_id=TXN,
        last_event_ts_ms=ts,
    )


def _event(
    *,
    cls: str,
    status: str,
    expires: datetime,
    ts: int,
    product_id: str = PID,
) -> SubscriptionEvent:
    return SubscriptionEvent(
        event_class=cls,
        product_id=product_id,
        status=status,
        expires_at=expires,
        rc_original_txn_id=TXN,
        event_ts_ms=ts,
    )


# --- Watermark: NULL-first applies -------------------------------------------


def test_null_watermark_first_event_applies():
    """A brand-new subscriber (no current row) must have its first webhook land,
    not be dropped by a None comparison (impl note i)."""
    ev = _event(
        cls=EVENT_CLASS_EXTEND, status=STATUS_ACTIVE, expires=_dt(2027), ts=1000
    )
    out = apply_subscription_event(None, ev)
    assert out == _state(status=STATUS_ACTIVE, expires=_dt(2027), ts=1000)


def test_null_watermark_on_existing_row_applies():
    """A row that exists but never took a ts-bearing event (watermark None) must
    still accept the first event."""
    cur = _state(status=STATUS_ACTIVE, expires=_dt(2026), ts=None)
    ev = _event(cls=EVENT_CLASS_EXTEND, status=STATUS_ACTIVE, expires=_dt(2027), ts=500)
    out = apply_subscription_event(cur, ev)
    assert out.expires_at == _dt(2027)
    assert out.last_event_ts_ms == 500


# --- Extend: max-wins --------------------------------------------------------


def test_extend_max_wins_pushes_expiry_forward():
    cur = _state(status=STATUS_ACTIVE, expires=_dt(2026), ts=1000)
    ev = _event(
        cls=EVENT_CLASS_EXTEND, status=STATUS_ACTIVE, expires=_dt(2027), ts=2000
    )
    out = apply_subscription_event(cur, ev)
    assert out.expires_at == _dt(2027)
    assert out.last_event_ts_ms == 2000


def test_extend_lower_expiry_keeps_current_but_advances_watermark():
    """An extend event whose expiry is *behind* current must not shorten it
    (max-wins), yet the newer watermark still advances so later staleness checks
    are correct."""
    cur = _state(status=STATUS_ACTIVE, expires=_dt(2028), ts=1000)
    ev = _event(
        cls=EVENT_CLASS_EXTEND, status=STATUS_ACTIVE, expires=_dt(2027), ts=2000
    )
    out = apply_subscription_event(cur, ev)
    assert out.expires_at == _dt(2028)  # unchanged
    assert out.last_event_ts_ms == 2000  # advanced


# --- Extend: status precedence on expires_at tie -----------------------------


def test_extend_tie_active_beats_grace():
    """Equal expiry -> higher status precedence (active > grace) wins wholesale."""
    cur = _state(status=STATUS_GRACE, expires=_dt(2027), ts=1000)
    ev = _event(
        cls=EVENT_CLASS_EXTEND, status=STATUS_ACTIVE, expires=_dt(2027), ts=2000
    )
    out = apply_subscription_event(cur, ev)
    assert out.status == STATUS_ACTIVE


def test_extend_tie_does_not_downgrade_active_to_grace():
    """A tie where current is the stronger status keeps current's status."""
    cur = _state(status=STATUS_ACTIVE, expires=_dt(2027), ts=1000)
    ev = _event(cls=EVENT_CLASS_EXTEND, status=STATUS_GRACE, expires=_dt(2027), ts=2000)
    out = apply_subscription_event(cur, ev)
    assert out.status == STATUS_ACTIVE
    assert out.last_event_ts_ms == 2000


# --- Revoke: moves expiry backward / flips expired ---------------------------


def test_revoke_moves_expiry_backward():
    """A refund on an annual sub must shorten expiry NOW, not leave ~11 months of
    unlimited. Pure max-wins could never do this — that's the whole reason for
    the split."""
    cur = _state(status=STATUS_ACTIVE, expires=_dt(2028), ts=1000)
    ev = _event(
        cls=EVENT_CLASS_REVOKE, status=STATUS_EXPIRED, expires=_dt(2026), ts=2000
    )
    out = apply_subscription_event(cur, ev)
    assert out.status == STATUS_EXPIRED
    assert out.expires_at == _dt(2026)


def test_revoke_flips_to_expired_on_equal_expiry():
    """An EXPIRATION-style revoke that leaves expiry equal but sets expired must
    still take effect (max-wins would have dropped it)."""
    cur = _state(status=STATUS_ACTIVE, expires=_dt(2027), ts=1000)
    ev = _event(
        cls=EVENT_CLASS_REVOKE, status=STATUS_EXPIRED, expires=_dt(2027), ts=2000
    )
    out = apply_subscription_event(cur, ev)
    assert out.status == STATUS_EXPIRED


# --- Watermark: stale events dropped in both directions ----------------------


def test_stale_extend_dropped():
    cur = _state(status=STATUS_ACTIVE, expires=_dt(2027), ts=2000)
    ev = _event(
        cls=EVENT_CLASS_EXTEND, status=STATUS_ACTIVE, expires=_dt(2030), ts=1000
    )
    out = apply_subscription_event(cur, ev)
    assert out is cur  # unchanged, no re-extend


def test_stale_revoke_dropped():
    """An out-of-order older revoke must not revoke a since-renewed sub."""
    cur = _state(status=STATUS_ACTIVE, expires=_dt(2027), ts=2000)
    ev = _event(
        cls=EVENT_CLASS_REVOKE, status=STATUS_EXPIRED, expires=_dt(2025), ts=1000
    )
    out = apply_subscription_event(cur, ev)
    assert out is cur


def test_equal_ts_dropped_not_strictly_newer():
    """Watermark is STRICTLY newer: an event at exactly the watermark is a replay
    and must be dropped."""
    cur = _state(status=STATUS_ACTIVE, expires=_dt(2027), ts=2000)
    ev = _event(
        cls=EVENT_CLASS_EXTEND, status=STATUS_ACTIVE, expires=_dt(2030), ts=2000
    )
    out = apply_subscription_event(cur, ev)
    assert out is cur


# --- Merge (D-merge): row-wise, no synthesized state -------------------------


def test_merge_row_wise_takes_greater_expiry_wholesale():
    """The winner's status must be its OWN status, never combined with the loser's
    expiry — the fold can't invent a pair neither row held."""
    a = _state(status=STATUS_GRACE, expires=_dt(2028), ts=1000)  # longer expiry, grace
    b = _state(status=STATUS_ACTIVE, expires=_dt(2026), ts=3000)  # shorter, active
    out = merge_subscription_rows(a, b)
    assert out.expires_at == _dt(2028)
    assert out.status == STATUS_GRACE  # comes WITH the winning row, not synthesized


def test_merge_last_event_ts_is_field_max():
    """last_event_ts_ms is resolved as a field-wise max independent of which row
    won on expiry."""
    a = _state(status=STATUS_GRACE, expires=_dt(2028), ts=1000)  # wins on expiry
    b = _state(status=STATUS_ACTIVE, expires=_dt(2026), ts=3000)  # larger ts
    out = merge_subscription_rows(a, b)
    assert out.last_event_ts_ms == 3000


def test_merge_expiry_tie_uses_status_precedence():
    a = _state(status=STATUS_EXPIRED, expires=_dt(2027), ts=1000)
    b = _state(status=STATUS_ACTIVE, expires=_dt(2027), ts=2000)
    out = merge_subscription_rows(a, b)
    assert out.status == STATUS_ACTIVE


def test_merge_none_ts_field_max_safe():
    a = _state(status=STATUS_ACTIVE, expires=_dt(2028), ts=None)
    b = _state(status=STATUS_ACTIVE, expires=_dt(2026), ts=5000)
    out = merge_subscription_rows(a, b)
    assert out.expires_at == _dt(2028)
    assert out.last_event_ts_ms == 5000


def test_merge_degrades_when_one_side_absent():
    only = _state(status=STATUS_ACTIVE, expires=_dt(2027), ts=1000)
    assert merge_subscription_rows(only, None) is only
    assert merge_subscription_rows(None, only) is only


# --- Event-type classification helper ----------------------------------------


def test_classify_unambiguous_types():
    assert classify_event_type("INITIAL_PURCHASE") == EVENT_CLASS_EXTEND
    assert classify_event_type("RENEWAL") == EVENT_CLASS_EXTEND
    assert classify_event_type("UNCANCELLATION") == EVENT_CLASS_EXTEND
    assert classify_event_type("REFUND") == EVENT_CLASS_REVOKE
    assert classify_event_type("CHARGEBACK") == EVENT_CLASS_REVOKE
    assert classify_event_type("CANCELLATION") == EVENT_CLASS_REVOKE
    assert classify_event_type("EXPIRATION") == EVENT_CLASS_REVOKE


def test_classify_product_change_requires_direction():
    assert (
        classify_event_type("PRODUCT_CHANGE", product_change_is_upgrade=True)
        == EVENT_CLASS_EXTEND
    )
    assert (
        classify_event_type("PRODUCT_CHANGE", product_change_is_upgrade=False)
        == EVENT_CLASS_REVOKE
    )
    with pytest.raises(ValueError):
        classify_event_type("PRODUCT_CHANGE")


def test_classify_unknown_type_raises():
    with pytest.raises(ValueError):
        classify_event_type("BOGUS_EVENT")
