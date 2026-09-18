"""#182 — `PACK_BATCH_SCHEDULE` parsing.

Why: the schedule decides how fast the first question reaches the player
(founder 2026-09-18: 1 → 2 → 4 → 8 → 8 → rest) and `0` is the only rollback
lever to the single-batch walk — a typo must neither disable incremental
delivery nor produce a zero-size batch that would loop the worker.
"""

import pytest

from app import feature_flags


@pytest.mark.parametrize(
    "raw, expected",
    [
        (None, (1, 2, 4, 8)),
        ("", (1, 2, 4, 8)),
        ("1,2,4,8", (1, 2, 4, 8)),
        (" 2, 4 ,8 ", (2, 4, 8)),
        ("0", ()),
        ("junk", (1, 2, 4, 8)),
        ("1,0,4", (1, 2, 4, 8)),
        (",", (1, 2, 4, 8)),
    ],
)
def test_pack_batch_schedule(monkeypatch, raw, expected):
    if raw is None:
        monkeypatch.delenv("PACK_BATCH_SCHEDULE", raising=False)
    else:
        monkeypatch.setenv("PACK_BATCH_SCHEDULE", raw)
    assert feature_flags.pack_batch_schedule() == expected
