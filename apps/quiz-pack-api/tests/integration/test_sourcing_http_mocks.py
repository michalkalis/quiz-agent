"""Sourcing-layer HTTP mock smoke test (issue #36 task 2.11b).

Constructs a real ``FactSourcer`` with all sources enabled and asserts that
``gather_facts`` returns at least four facts with non-null ``source_url`` when
every back-end HTTP call is intercepted by the ``sourcing_http_mocks`` fixture.

This pins the contract between ``FactSourcer`` and the mock route shapes — if
a source's response parsing breaks, this test fails before the slower e2e
pipeline test in ``test_order_e2e.py``.
"""

from __future__ import annotations

import pytest

from app.sourcing.fact_sourcer import FactSourcer


@pytest.fixture(autouse=True)
def _tavily_api_key(monkeypatch: pytest.MonkeyPatch) -> None:
    """``WebSearchSource.__init__`` raises without a TAVILY_API_KEY env var."""
    monkeypatch.setenv("TAVILY_API_KEY", "test-key-for-mocks")


async def test_fact_sourcer_returns_facts_under_mocks(sourcing_http_mocks) -> None:
    sourcer = FactSourcer()
    batch = await sourcer.gather_facts(count=10)

    with_url = [f for f in batch.facts if f.source_url]
    assert len(with_url) >= 4, (
        f"expected ≥ 4 facts with non-null source_url under mocked HTTP, "
        f"got {len(with_url)}: "
        f"{[(f.source_name, f.source_url) for f in batch.facts]}"
    )
