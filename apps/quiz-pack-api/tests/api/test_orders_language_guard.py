"""#231 — Ukrainian as a fourth language: the order guard keeps uk dark.

Offline twin of the database-backed order tests in test_orders.py: the guard is
a pure function of the body and the env, so this runs everywhere.

Why it matters: an accepted pack order is generated and paid for. Before this
guard, "known to the data model" meant "accepted with a warning", so the env
list only hid Ukrainian from the menu while a direct order still went through.
"""

from __future__ import annotations

from types import SimpleNamespace

import pytest
from app.api.v1.orders import _validate_guards
from fastapi import HTTPException


def _body(language: str):
    return SimpleNamespace(prompt="space", language=language)


def test_ukrainian_order_is_refused_until_listed(monkeypatch):
    monkeypatch.delenv("PACK_ORDER_LANGUAGES", raising=False)
    with pytest.raises(HTTPException) as exc:
        _validate_guards(_body("uk"))
    assert exc.value.status_code == 422
    assert "uk" in exc.value.detail

    # Listing it is an env flip, no code change.
    monkeypatch.setenv("PACK_ORDER_LANGUAGES", "en,sk,cs,uk")
    _validate_guards(_body("uk"))


@pytest.mark.parametrize("language", ["en", "sk", "cs", "de", "fr"])
def test_other_languages_behave_as_before(monkeypatch, language):
    """Orderable ones pass; legacy hidden ones (de, fr) are still only warned
    about, because installed builds still offer them and the purchase is paid."""
    monkeypatch.delenv("PACK_ORDER_LANGUAGES", raising=False)
    _validate_guards(_body(language))


def test_unknown_language_still_422():
    with pytest.raises(HTTPException) as exc:
        _validate_guards(_body("xx"))
    assert exc.value.status_code == 422
