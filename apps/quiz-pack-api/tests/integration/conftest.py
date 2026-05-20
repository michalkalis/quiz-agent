"""Integration-test conftest — HTTP egress guard (issue #36 task 2.11a).

The autouse ``_block_external_http`` fixture wraps every integration test in a
``respx.mock`` context with ``assert_all_mocked=True``. Any HTTPS request made
through ``httpx`` that doesn't match a registered route raises immediately,
which keeps real LLM / Tavily / Wikipedia calls out of CI even if the test
forgets to mock them.

Tasks 2.11b–e add the concrete route groups (sourcing, generation, verify,
score). Until then the e2e tests are marked ``xfail`` — the guard is in place
but the routes aren't, so unmocked calls *would* raise.
"""

from __future__ import annotations

from typing import Iterator

import pytest
import respx


@pytest.fixture(autouse=True)
def _block_external_http() -> Iterator[respx.MockRouter]:
    """Block any unmocked HTTPS request during integration tests.

    Tests that need real routes register them on the yielded ``MockRouter``.
    ``assert_all_called=False`` so unused routes don't fail the test (a route
    group registered by 2.11b may not be hit by every test).
    """
    with respx.mock(assert_all_called=False, assert_all_mocked=True) as router:
        yield router
