"""#231 — Ukrainian: order refusals a Ukrainian player reads verbatim.

Shipped builds show these server messages as-is, so a Ukrainian interface must
get Ukrainian text, not the English fallback, and the tester-cap date must read
as a Ukrainian date (day + genitive month), not the Slovak/Czech "25. 11".
"""

from __future__ import annotations

from datetime import UTC, datetime

from app.api.v1.orders import _orders_paused_detail, _tester_cap_detail


def test_paused_message_is_ukrainian_for_a_ukrainian_client():
    assert _orders_paused_detail("uk-UA,uk;q=0.9", paid=False) == (
        "Замовлення поки що призупинені. Спробуй пізніше."
    )
    assert _orders_paused_detail("uk", paid=True) == (
        "Замовлення поки що призупинені. Оплата збережена, спробуй пізніше."
    )


def test_tester_cap_date_reads_as_a_ukrainian_date():
    detail = _tester_cap_detail("uk-UA", datetime(2026, 11, 25, tzinfo=UTC))
    assert detail == (
        "Тижневий ліміт тестових наборів вичерпано. Наступний можна створити з 25 листопада."
    )


def test_slovak_and_english_are_unchanged():
    when = datetime(2026, 11, 25, tzinfo=UTC)
    assert _tester_cap_detail("sk-SK", when).endswith("od 25. 11.")
    assert _tester_cap_detail("en", when).endswith("on Nov 25.")
