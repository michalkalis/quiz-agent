"""Turns the aggregated rows into stat cards (#213). Pure, no I/O.

A card is ``{kind, state, progress, data}``. ``kind``/``state``/``unit`` are
plain strings so a new card or unit never breaks an app build that predates it.
Correct = ``result == "correct"``; partial credit counts as not correct, so
accuracy reads as the plain "got it right" share the player remembers.
"""

from __future__ import annotations

from collections import Counter, defaultdict
from statistics import median
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from .config import (
    AUDIO_ROUTE_GROUPS,
    HARD_DIFFICULTY,
    MCQ_TYPE,
    PARTS_OF_DAY,
)
from .config import (
    THRESHOLDS as T,
)
from .queries import DimRow, GameRow, SpeedRow

Req = tuple[int, int, str]  # (current, target, unit)
WEEKDAYS = (
    "monday",
    "tuesday",
    "wednesday",
    "thursday",
    "friday",
    "saturday",
    "sunday",
)


def pct(correct: int, total: int) -> int:
    return round(100 * correct / total) if total else 0


def make_card(kind: str, reqs: list[Req], data: dict) -> dict:
    """Locked until every requirement is met; progress shows the most binding
    (largest missing share) one so the player sees the nearest next step."""
    unmet = [r for r in reqs if r[0] < r[1]]
    if not unmet:
        cur, target, unit = reqs[0]
        return {
            "kind": kind,
            "state": "unlocked",
            "progress": {"current": target, "target": target, "unit": unit},
            "data": data,
        }
    cur, target, unit = max(unmet, key=lambda r: 1 - r[0] / r[1])
    return {
        "kind": kind,
        "state": "locked",
        "progress": {"current": cur, "target": target, "unit": unit},
        "data": {},
    }


def _zone(name: str | None) -> ZoneInfo | None:
    if not name:
        return None
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        return None


class Game:
    """One game with its local start time and length resolved."""

    def __init__(self, row: GameRow, zone: ZoneInfo):
        self.row = row
        self.start = row.started_at or row.first_at
        self.local = self.start.astimezone(zone)
        minutes = max((row.last_at - self.start).total_seconds(), 0) / 60
        self.minutes = min(minutes, T["max_game_minutes"])


def build_games(rows: list[GameRow], fallback_tz: str) -> list[Game]:
    """Local time uses the game's own timezone; a game from before the app sent
    one borrows the nearest game's, else ``fallback_tz`` (UTC by default)."""
    zones = {r.session_id: _zone(r.timezone) for r in rows}
    known = [r for r in rows if zones[r.session_id] is not None]
    fallback = _zone(fallback_tz) or ZoneInfo("UTC")
    games = []
    for r in rows:
        zone = zones[r.session_id]
        if zone is None and known:
            near = min(
                known, key=lambda k: abs((k.first_at - r.first_at).total_seconds())
            )
            zone = zones[near.session_id]
        games.append(Game(r, zone or fallback))
    return games


def part_of_day(hour: int) -> str:
    for name, lo, hi in PARTS_OF_DAY:
        if lo <= hour < hi:
            return name
    return "night"


def _accuracy_by_category(dims: list[DimRow]) -> list[tuple[str, int, int]]:
    """(category, answers, correct) for categories with enough answers."""
    agg: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    for d in dims:
        if d.category:
            agg[d.category][0] += d.answers
            agg[d.category][1] += d.correct
    return [(c, n, k) for c, (n, k) in agg.items() if n >= T["category_min_answers"]]


def category_cards(dims: list[DimRow]) -> list[dict]:
    eligible = _accuracy_by_category(dims)
    reqs: list[Req] = [(len(eligible), T["category_min_categories"], "categories")]
    ranked = sorted(eligible, key=lambda e: (-e[2] / e[1], -e[1], e[0]))
    data_best: dict = {}
    data_weak: dict = {}
    if len(eligible) >= T["category_min_categories"]:
        c, n, k = ranked[0]
        lead = pct(k, n) - pct(ranked[1][2], ranked[1][1])
        standout = lead >= T["standout_lead_points"]
        data_best = {
            "category": c,
            "accuracy": pct(k, n),
            "answers": n,
            "standout": standout,
            "versatile": not standout,
        }
        c, n, k = min(eligible, key=lambda e: (e[2] / e[1], -e[1], e[0]))
        data_weak = {"category": c, "accuracy": pct(k, n), "answers": n}
    return [
        make_card("best_category", reqs, data_best),
        make_card("weakest_category", reqs, data_weak),
    ]


def where_card(games: list[Game]) -> dict:
    ctx = [g for g in games if g.row.has_context]
    groups = Counter(
        AUDIO_ROUTE_GROUPS.get(g.row.audio_route or "", "other") for g in ctx
    )
    data = {}
    if groups:
        top, count = max(groups.items(), key=lambda kv: (kv[1], kv[0]))
        data = {
            "top": top,
            "share": pct(count, len(ctx)),
            "games": len(ctx),
            "breakdown": dict(groups),
        }
    return make_card("where", [(len(ctx), T["where_min_games"], "games")], data)


def when_card(games: list[Game]) -> dict:
    ctx = [g for g in games if g.row.has_context]
    days = {g.local.date() for g in ctx}
    data = {}
    if ctx:
        parts = Counter(part_of_day(g.local.hour) for g in ctx)
        wd = Counter(g.local.weekday() for g in ctx)
        data = {
            "part_of_day": max(parts.items(), key=lambda kv: (kv[1], kv[0]))[0],
            "weekday": WEEKDAYS[max(wd.items(), key=lambda kv: (kv[1], -kv[0]))[0]],
            "games": len(ctx),
        }
    return make_card(
        "when",
        [
            (len(ctx), T["when_min_games"], "games"),
            (len(days), T["when_min_days"], "days"),
        ],
        data,
    )


def typical_card(games: list[Game]) -> dict:
    data = {}
    if games:
        data = {
            "minutes": round(median(g.minutes for g in games), 1),
            "answers": round(median(g.row.answers for g in games)),
        }
    return make_card(
        "typical_game", [(len(games), T["typical_min_games"], "games")], data
    )


def totals_card(games: list[Game], dims: list[DimRow]) -> dict:
    answers = sum(d.answers for d in dims)
    data = {
        "answers": answers,
        "games": len(games),
        "minutes": round(sum(g.minutes for g in games)),
    }
    return {
        "kind": "totals",
        "state": "unlocked",
        "progress": {"current": 0, "target": 0, "unit": "answers"},
        "data": data,
    }


def streak_card(games: int, streak: int) -> dict:
    return make_card(
        "best_streak", [(games, T["streak_min_games"], "games")], {"length": streak}
    )


def hard_card(dims: list[DimRow]) -> dict:
    hard = [d for d in dims if d.difficulty == HARD_DIFFICULTY]
    n, k = sum(d.answers for d in hard), sum(d.correct for d in hard)
    return make_card(
        "hard_questions",
        [(n, T["hard_min_answers"], "answers")],
        {"answers": n, "correct": k, "accuracy": pct(k, n)},
    )


def mcq_open_card(dims: list[DimRow]) -> dict:
    mcq = [d for d in dims if d.qtype == MCQ_TYPE]
    opn = [d for d in dims if d.qtype != MCQ_TYPE]
    mn, mk = sum(d.answers for d in mcq), sum(d.correct for d in mcq)
    on, ok = sum(d.answers for d in opn), sum(d.correct for d in opn)
    gap = pct(mk, mn) - pct(ok, on)
    better = (
        "even"
        if abs(gap) < T["mcq_open_even_points"]
        else ("mcq" if gap > 0 else "open")
    )
    need = T["mcq_open_min_each"]
    return make_card(
        "mcq_vs_open",
        [(mn, need, "answers"), (on, need, "answers")],
        {
            "mcq": {"answers": mn, "accuracy": pct(mk, mn)},
            "open": {"answers": on, "accuracy": pct(ok, on)},
            "better": better,
        },
    )


def improvement_card(total: int, days: int, thirds: list[tuple]) -> dict:
    """Accuracy of the last third minus the first third, difficulty by
    difficulty (a harder stretch must not read as getting worse), weighted by
    how many answers each difficulty has."""
    reqs: list[Req] = [
        (total, T["improvement_min_answers"], "answers"),
        (days, T["improvement_min_days"], "days"),
    ]
    cells: dict[str | None, dict[int, tuple[int, int]]] = defaultdict(dict)
    for tile, diff, n, k in thirds:
        cells[diff][tile] = (n, k)
    num = den = 0.0
    for tiles in cells.values():
        if 1 in tiles and 3 in tiles:
            (n1, k1), (n3, k3) = tiles[1], tiles[3]
            w = n1 + n3
            num += w * (100 * k3 / n3 - 100 * k1 / n1)
            den += w
    delta = round(num / den) if den else 0
    steady = abs(delta) < T["improvement_steady_points"]
    direction = "steady" if steady else ("up" if delta > 0 else "down")
    return make_card(
        "improvement",
        reqs,
        {"delta_points": delta, "direction": direction, "days": days},
    )


def speed_card(rows: list[SpeedRow]) -> dict:
    ok = sorted(
        (r for r in rows if r.measured >= T["speed_min_answers"]),
        key=lambda r: (r.median_ms, r.category),
    )
    data = {}
    if len(ok) >= T["speed_min_categories"]:
        data = {
            "fastest": {
                "category": ok[0].category,
                "median_ms": round(ok[0].median_ms),
            },
            "slowest": {
                "category": ok[-1].category,
                "median_ms": round(ok[-1].median_ms),
            },
        }
    return make_card(
        "fastest_slowest", [(len(ok), T["speed_min_categories"], "categories")], data
    )


def span_days(games: list[Game]) -> int:
    if not games:
        return 0
    first = min(g.row.first_at for g in games)
    last = max(g.row.last_at for g in games)
    return (last - first).days


def local_days(games: list[Game]) -> int:
    return len({g.local.date() for g in games})
