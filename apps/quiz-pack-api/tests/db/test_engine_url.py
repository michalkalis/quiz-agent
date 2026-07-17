"""``normalize_async_url`` must swallow libpq-only query params (#101).

``fly postgres attach`` (staging DB provisioning) emits
``postgres://...?sslmode=disable``; asyncpg's ``connect()`` rejects
``sslmode`` with a TypeError on first DB touch. Pin the translation so an
attach-provisioned environment boots against its URL verbatim.
"""

from app.db.engine import normalize_async_url


def test_fly_attach_sslmode_disable_is_dropped():
    assert normalize_async_url("postgres://u:p@h:5432/db?sslmode=disable") == (
        "postgresql+asyncpg://u:p@h:5432/db"
    )


def test_sslmode_require_translates_to_ssl_true():
    assert normalize_async_url("postgresql://u:p@h/db?sslmode=require") == (
        "postgresql+asyncpg://u:p@h/db?ssl=true"
    )


def test_other_params_survive_and_channel_binding_dropped():
    assert normalize_async_url(
        "postgres://u:p@h/db?sslmode=disable&application_name=x&channel_binding=prefer"
    ) == "postgresql+asyncpg://u:p@h/db?application_name=x"
