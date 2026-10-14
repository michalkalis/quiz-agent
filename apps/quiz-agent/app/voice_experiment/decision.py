"""Pure decision logic for the voice-settings test (#204 task 204.9).

No I/O: the evaluator hands in the ``answer_captured`` events and one
experiment row, this module picks the answers that count, scores them and
says whether the row is decided. Kept pure so every threshold is unit-tested
without a database.

Method: Beta(1,1) prior on each arm's bad-capture rate, Monte Carlo with a
fixed seed (same data → same verdict every week), and the expected-loss stop
rule (Stucchio, "Bayesian A/B testing decision rule"): turn the setting on
only when it is very likely better AND choosing it costs almost nothing if
it is not.
"""

from __future__ import annotations

import random
import statistics
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Any

# Thresholds from the 204.9 contract.
WIN_MIN_N = 40
HARM_MIN_N = 20
CONFIDENCE = 0.95
MAX_EXPECTED_LOSS = 0.01
MAX_RUNNING = timedelta(weeks=6)
DRAWS = 20_000
SEED = 2049

# A setting only counts on answers where it could have had an effect.
APPLICABLE_KEY = {"aec": "aec_applicable", "front_mic": "front_mic_applicable"}


@dataclass(frozen=True)
class Capture:
    """One stored ``answer_captured`` event (envelope + properties)."""

    session_id: str | None
    occurred_at: datetime
    properties: dict[str, Any]


@dataclass(frozen=True)
class ArmRow:
    flag: str
    route_group: str
    generation: int
    started_at: datetime


@dataclass
class ArmStats:
    n: int = 0
    bad: int = 0
    end_delays_ms: list[int] = field(default_factory=list)
    graded: int = 0
    correct: int = 0

    def summary(self) -> dict[str, Any]:
        return {
            "n": self.n,
            "bad": self.bad,
            "bad_rate": round(self.bad / self.n, 4) if self.n else None,
            "median_end_delay_ms": (
                int(statistics.median(self.end_delays_ms))
                if self.end_delays_ms
                else None
            ),
            "correct_share": (
                round(self.correct / self.graded, 4) if self.graded else None
            ),
        }


@dataclass(frozen=True)
class Decision:
    flag: str
    route_group: str
    status: str  # winner_on | off
    p_on: float
    reason: str  # winner | harm | no_difference


def _key(c: Capture) -> tuple[str, str] | None:
    qid = c.properties.get("question_id")
    return (c.session_id, qid) if c.session_id and qid else None


def rejected_flags(captures: list[Capture]) -> dict[int, bool]:
    """``id(capture)`` → rejected: the NEXT capture of the same question in the
    same session carries a higher ``rejected_count`` (the player said "no,
    again" to this one's transcript). The count is cumulative, so comparing
    with any later capture would also blame earlier attempts. One sort,
    O(n log n), computed once per evaluation."""
    keyed = sorted(
        ((k, c) for c in captures if (k := _key(c)) is not None),
        key=lambda kc: (kc[0], kc[1].occurred_at),
    )
    out: dict[int, bool] = {}
    for (k, c), (next_k, nxt) in zip(keyed, keyed[1:] + [(None, None)]):
        out[id(c)] = next_k == k and _rc(nxt) > _rc(c)
    return out


def _rc(c: Capture) -> int:
    return c.properties.get("rejected_count") or 0


def is_bad(c: Capture, rejected: bool) -> bool:
    p = c.properties
    return p.get("stop_reason") == "cap" or p.get("heard_speech") is False or rejected


def counts_for(c: Capture, row: ArmRow) -> bool:
    """Whether this answer belongs to the row's test: the coin decided the
    setting (``src`` auto) in this generation, on this route, where the
    setting could act, and the effective value is known."""
    p, flag = c.properties, row.flag
    applicable = APPLICABLE_KEY.get(flag)
    return (
        c.occurred_at >= row.started_at
        and p.get(f"src_{flag}") == "auto"
        and p.get(f"exp_gen_{flag}") == row.generation
        and p.get("route_group") == row.route_group
        and (applicable is None or p.get(applicable) is True)
        and isinstance(p.get(flag), bool)
    )


def aggregate(
    captures: list[Capture],
    row: ArmRow,
    verdicts: dict[tuple[str, str], str] | None = None,
    rejected: dict[int, bool] | None = None,
) -> dict[bool, ArmStats]:
    """Per-arm counts for one row. ``captures`` is every answer_captured event
    in the window (the rejection lookup needs the retries too); ``verdicts``
    maps (session_id, question_id) → answer_evaluated result, report only;
    ``rejected`` is ``rejected_flags(captures)`` when the caller has it."""
    if rejected is None:
        rejected = rejected_flags(captures)
    arms = {True: ArmStats(), False: ArmStats()}
    graded_keys: dict[bool, set] = {True: set(), False: set()}
    for c in captures:
        if not counts_for(c, row):
            continue
        arm = arms[c.properties[row.flag]]
        arm.n += 1
        arm.bad += is_bad(c, rejected.get(id(c), False))
        delay = c.properties.get("end_delay_ms")
        if isinstance(delay, int) and not isinstance(delay, bool):
            arm.end_delays_ms.append(delay)
        k = _key(c)
        if verdicts and k in verdicts and k not in graded_keys[c.properties[row.flag]]:
            graded_keys[c.properties[row.flag]].add(k)
            arm.graded += 1
            arm.correct += verdicts[k] == "correct"
    return arms


def posterior(on: ArmStats, off: ArmStats) -> dict[str, float]:
    """Monte Carlo over Beta(1+bad, 1+good) per arm (lower bad rate = better)."""
    rng = random.Random(SEED)
    better = worse = loss = 0.0
    for _ in range(DRAWS):
        b_on = rng.betavariate(1 + on.bad, 1 + on.n - on.bad)
        b_off = rng.betavariate(1 + off.bad, 1 + off.n - off.bad)
        better += b_on < b_off
        worse += b_on > b_off
        loss += max(b_on - b_off, 0.0)
    return {
        "p_on_better": round(better / DRAWS, 4),
        "p_on_worse": round(worse / DRAWS, 4),
        "expected_loss_on": round(loss / DRAWS, 5),
    }


def decide(
    row: ArmRow, on: ArmStats, off: ArmStats, post: dict[str, float], now: datetime
) -> Decision | None:
    """Harm first (stop hurting players early), then winner, then the 6-week
    cap. ``None`` = keep running."""
    if min(on.n, off.n) >= HARM_MIN_N and post["p_on_worse"] >= CONFIDENCE:
        return Decision(row.flag, row.route_group, "off", 0.0, "harm")
    if (
        min(on.n, off.n) >= WIN_MIN_N
        and post["p_on_better"] >= CONFIDENCE
        and post["expected_loss_on"] < MAX_EXPECTED_LOSS
    ):
        return Decision(row.flag, row.route_group, "winner_on", 1.0, "winner")
    if now - row.started_at >= MAX_RUNNING:
        return Decision(row.flag, row.route_group, "off", 0.0, "no_difference")
    return None


def score_rows(
    rows: list[ArmRow],
    captures: list[Capture],
    verdicts: dict[tuple[str, str], str],
    now: datetime,
) -> list[tuple[ArmRow, dict[bool, ArmStats], dict[str, float], Decision | None]]:
    """Everything CPU-bound for one evaluation, so the caller can run it off
    the event loop: rejection flags once, then per row counts, posterior and
    verdict."""
    rejected = rejected_flags(captures)
    out = []
    for row in rows:
        stats = aggregate(captures, row, verdicts, rejected)
        post = posterior(stats[True], stats[False])
        out.append(
            (row, stats, post, decide(row, stats[True], stats[False], post, now))
        )
    return out
