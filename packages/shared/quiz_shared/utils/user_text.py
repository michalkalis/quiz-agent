"""Free text a player typed or pasted, cleaned before the server keeps it.

Pasting must keep working, so nothing visible is touched. Only characters a
person cannot see are dropped: control characters (except newline and tab)
and the bidi overrides/isolates that make text render in a different order
than it is stored — the classic trick for a name or prompt that reads one way
and means another. Zero-width joiners stay: emoji sequences need them.
"""

from __future__ import annotations

import re
import unicodedata

_BIDI_AND_INVISIBLE = re.compile("[​‪-‮⁦-⁩﻿]")


def clean_user_text(text: str) -> str:
    """``text`` without invisible control/bidi characters; never truncates."""
    text = _BIDI_AND_INVISIBLE.sub("", text)
    return "".join(
        ch for ch in text if ch in "\n\t" or unicodedata.category(ch) != "Cc"
    )
