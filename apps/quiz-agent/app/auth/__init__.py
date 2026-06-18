"""Self-owned auth layer for quiz-agent (issue #60).

Server-trusted anonymous identity: signed access tokens (PyJWT/HS256) +
rotating refresh tokens. No managed auth provider — tokens are minted and
verified by this service against the existing Postgres.
"""
