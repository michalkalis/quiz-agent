"""``normalize_async_url`` must translate libpq-only query params (#101).

``fly postgres attach`` (used to provision the staging DB) emits
``postgres://...?sslmode=disable``; passing ``sslmode`` through to asyncpg
raises ``TypeError: connect() got an unexpected keyword argument 'sslmode'``
on the FIRST DB touch — which surfaced as a 500 on the staging RC webhook.
Dropping the param is NOT a fix: asyncpg then defaults to ``prefer`` and the
flycast LB hard-resets the TLS handshake (ConnectionResetError, verified on
the staging machine). asyncpg accepts the same sslmode values under ``ssl``,
so the key is renamed and the value kept. These tests pin that translation so
any attach-provisioned environment (the 3rd env included) boots verbatim.
"""

from app.db.engine import normalize_async_url


def test_scheme_rewrite_plain():
    assert normalize_async_url("postgres://u:p@h:5432/db") == (
        "postgresql+asyncpg://u:p@h:5432/db"
    )


def test_fly_attach_sslmode_disable_renamed_to_ssl():
    assert normalize_async_url("postgres://u:p@h:5432/db?sslmode=disable") == (
        "postgresql+asyncpg://u:p@h:5432/db?ssl=disable"
    )


def test_sslmode_require_keeps_value_under_ssl():
    assert normalize_async_url("postgresql://u:p@h/db?sslmode=require") == (
        "postgresql+asyncpg://u:p@h/db?ssl=require"
    )


def test_other_params_survive_and_channel_binding_dropped():
    assert (
        normalize_async_url(
            "postgres://u:p@h/db?sslmode=disable&application_name=x&channel_binding=prefer"
        )
        == "postgresql+asyncpg://u:p@h/db?ssl=disable&application_name=x"
    )


def test_already_asyncpg_url_untouched():
    assert normalize_async_url("postgresql+asyncpg://u:p@h/db") == (
        "postgresql+asyncpg://u:p@h/db"
    )
