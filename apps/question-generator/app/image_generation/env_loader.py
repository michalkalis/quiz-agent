"""Load .env file from project root into os.environ."""

import os
from pathlib import Path

_PROJECT_ROOT = Path(__file__).parent.parent.parent.parent.parent


def load_env() -> None:
    """Parse the root .env file and set missing environment variables."""
    env_file = _PROJECT_ROOT / ".env"
    if not env_file.exists():
        return
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, val = line.partition("=")
            os.environ.setdefault(key.strip(), val.strip())
