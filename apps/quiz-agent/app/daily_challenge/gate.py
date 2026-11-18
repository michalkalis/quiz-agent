"""Who sees the daily challenge (#205): everyone once the env switch
``DAILY_CHALLENGE_ENABLED`` is on; before that only beta builds, so the
founder tests it in Trubbo Beta while App Store builds (which already contain
the Home card) keep it hidden.

Installed builds send no channel on ``/app-config`` or the daily routes, but
every iOS request carries the default CFNetwork User-Agent
``<bundle name>/<build> CFNetwork/<v> Darwin/<v>``. Its build number is the one
signal already-installed builds send: builds at or above the DB switch
``daily_challenge_beta_min_build`` count as beta. Raise or clear the switch
before a store build at or above it ships.
"""

from __future__ import annotations

import re

from fastapi import Request

from .. import app_switches
from ..config import get_settings

_UA_BUILD = re.compile(r"^[^/\s]+/(\d+) CFNetwork/")


def build_from_user_agent(user_agent: str | None) -> int | None:
    """The app's build number from a CFNetwork User-Agent, else ``None``."""
    match = _UA_BUILD.match(user_agent or "")
    return int(match.group(1)) if match else None


async def daily_challenge_on(request: Request, sessionmaker) -> bool:
    settings = get_settings()
    if settings.daily_challenge_enabled:
        return True
    switches = app_switches.effective(
        settings, await app_switches.cached_overrides(sessionmaker)
    )
    min_build = switches["daily_challenge_beta_min_build"]
    build = build_from_user_agent(request.headers.get("user-agent"))
    return min_build is not None and build is not None and build >= int(min_build)
