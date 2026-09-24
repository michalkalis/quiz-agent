"""Opt-in client capabilities, declared once per session (#185).

Shipped iOS binaries cannot be changed, so any response the #185 fixes reshape
is opt-in: a client announces what it understands in the
``X-Client-Capabilities`` header when it creates the session (comma-separated
tokens, unknown ones ignored), the session remembers it, and every later route
serves that client the new behaviour. A session created without the header
keeps today's contract byte for byte — the same pattern as ``X-Build-Channel``.

Tokens:

- ``answer-codes`` — "say it again" 400s from the submit routes carry a
  machine-readable ``detail.code`` (``no_speech`` / ``no_answer`` /
  ``mcq_unmatched``), and an MCQ answer that names no option is refused with
  ``mcq_unmatched`` instead of being graded "incorrect".
- ``option-labels`` — question audio reads the MCQ options with the served
  ``option_labels`` ("1".."4", or "A".."D" when the options are numbers)
  instead of the raw keys, matching what the client now displays.
"""

from __future__ import annotations

from typing import Any, Optional

CAPABILITIES_HEADER = "X-Client-Capabilities"
ANSWER_CODES = "answer-codes"
OPTION_LABELS = "option-labels"
KNOWN_CAPABILITIES = frozenset({ANSWER_CODES, OPTION_LABELS})


def parse_capabilities(header_value: Optional[str]) -> list[str]:
    """Whitelisted, de-duplicated tokens from the header (garbage never widens)."""
    if not header_value:
        return []
    tokens = {t.strip().lower() for t in header_value.split(",")}
    return sorted(tokens & KNOWN_CAPABILITIES)


def has_capability(session: Any, capability: str) -> bool:
    return capability in (getattr(session, "client_capabilities", None) or ())
