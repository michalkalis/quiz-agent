#!/usr/bin/env python3
"""Dump the FastAPI OpenAPI schema to stdout without starting the server.

The `verify-api-models` CI job only needs the OpenAPI schema (to diff iOS Codable
structs against backend Pydantic models) — not a running backend. Booting uvicorn
hangs in CI: the startup lifespan pre-generates static TTS feedback audio, which
needs ffmpeg/ffprobe and a real TTS provider, neither available on the runner, so
the server never finishes startup and never binds the port.

`app.openapi()` introspects the route table and Pydantic models directly. Importing
`app.main` does NOT run lifespan startup events, so none of that heavy I/O fires.
"""

import json
import sys

from app.main import app

json.dump(app.openapi(), sys.stdout)
