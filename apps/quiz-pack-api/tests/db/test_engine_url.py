"""``normalize_async_url`` must translate libpq-only query params (#101).

``fly postgres attach`` (staging DB provisioning) emits
``postgres://...?sslmode=disable``; asyncpg's ``connect()`` rejects
``sslmode`` with a TypeError on first DB touch, and dropping the param makes
asyncpg default to ``prefer`` — the flycast LB hard-resets that TLS handshake
(ConnectionResetError, verified on the staging machine). asyncpg accepts the
same sslmode values under ``ssl``, so the key is renamed and the value kept.
"""

from app.db.engine import normalize_async_url


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
