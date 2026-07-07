"""Async SQLAlchemy + Alembic layer for auth/usage persistence (issue #60).

Holds the auth Phase 1 tables (anonymous_identities, refresh_tokens,
daily_usage) on the existing ``DATABASE_URL`` Postgres. Separate from the
pgvector question store and the SQLite ratings store.
"""
