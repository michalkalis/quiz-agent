"""Per-category strictness profiles (#170 D6, task 170.8).

Why these tests matter:
- The kv string is the ONLY way the founder tunes dedup strictness without
  a code change; a typo that silently parsed as "no override" would be a
  silent loosening (or tightening) of dedup — so malformed input must fail
  at parse time, loudly.
- An empty profile set must resolve every lever to the global default the
  caller passes: that is the "flag OFF = today's behaviour" guarantee.
"""

from __future__ import annotations

import pytest
from app.orchestrator.stages.strictness import (
    ANSWER_CAP_DEFAULT,
    NO_STRICTNESS,
    Strictness,
    StrictnessProfile,
    parse_strictness,
)


def test_parses_the_d6_starting_profile() -> None:
    profiles = parse_strictness(
        "entertainment=cosine:0.92,in_batch:0.72,fact:0.45,cap:6; sports = cap:4"
    )
    assert profiles == {
        "entertainment": StrictnessProfile(
            cosine=0.92, in_batch=0.72, fact=0.45, cap=6
        ),
        "sports": StrictnessProfile(cap=4),
    }


def test_empty_or_none_is_no_profiles() -> None:
    assert parse_strictness(None) == {}
    assert parse_strictness("  ; ") == {}


@pytest.mark.parametrize(
    "raw",
    [
        "entertainment",  # no '='
        "entertainment=cosine",  # lever without value
        "entertainment=cosinus:0.9",  # unknown lever
        "entertainment=cosine:abc",  # not a number
        "entertainment=cosine:1.5",  # out of (0, 1]
        "entertainment=cap:0",  # cap < 1
        "entertainment=cap:3;entertainment=cap:4",  # duplicate category
        "=cap:3",  # empty category
    ],
)
def test_malformed_kv_fails_loud(raw: str) -> None:
    with pytest.raises(ValueError):
        parse_strictness(raw)


def test_levers_resolve_to_caller_defaults_without_a_profile() -> None:
    s = NO_STRICTNESS
    assert s.cosine_for("entertainment", 0.85) == 0.85
    assert s.in_batch_for("sports", 0.60) == 0.60
    assert s.fact_for(None, 0.35) == 0.35
    assert s.cap_for("anything") == ANSWER_CAP_DEFAULT == 3
    assert s.answer_cap is False


def test_profile_overrides_only_the_levers_it_names() -> None:
    s = Strictness(profiles=parse_strictness("entertainment=cosine:0.92,cap:6"))
    assert s.cosine_for("Entertainment", 0.85) == 0.92  # case-insensitive lookup
    assert s.in_batch_for("entertainment", 0.60) == 0.60  # not named → default
    assert s.cap_for("entertainment") == 6
    assert s.cap_for("history") == 3
