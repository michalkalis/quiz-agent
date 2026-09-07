"""Per-category dedup strictness profiles (#170 D6, locked 1/6/6a).

One profile per category carries **every** relaxable dedup lever at once —
`cosine` (question-only AND question+answer thresholds, B1), `in_batch`
Jaccard, `fact` content Jaccard — plus `cap`, the per-category ceiling on
how many corpus rows may share one normalized answer (ANSWER_CAP). A
category without a profile keeps the global defaults untouched, so an empty
profile set is exactly today's behaviour. The exact `fact_key` match
(same source URL + same answer) stays global on purpose: it is an equality,
not a similarity threshold, and relaxing it would admit literal repeats.

Configuration form (read ONLY by `scripts/generate_pack.py`, D5 — never by a
stage, never by the customer-pack worker): one kv string, one entry per
category, e.g.

    DEDUP_STRICTNESS_PER_CATEGORY="entertainment=cosine:0.92,in_batch:0.72,fact:0.45,cap:6;sports=cap:4"

Entries are `;`-separated, levers `,`-separated, `lever:value`. Malformed
input fails loud at parse time — a silently ignored typo would be a silent
loosening of dedup.

Founder-proposed starting profiles (issue-170 D6): entertainment 6 / 0.92 /
0.72 / 0.45; sports 4 + defaults; the rest cap 3 (global default) + defaults.
"""

from __future__ import annotations

from dataclasses import dataclass

# Locked 6: no fixed global number, rather loose; 3 = "the third repeat of
# the same answer in one category is already a mode-collapse signal".
ANSWER_CAP_DEFAULT = 3

_LEVERS = ("cosine", "in_batch", "fact", "cap")


@dataclass(frozen=True)
class StrictnessProfile:
    """Overrides for one category; ``None`` = keep the global default."""

    cosine: float | None = None
    in_batch: float | None = None
    fact: float | None = None
    cap: int | None = None


def parse_strictness(raw: str | None) -> dict[str, StrictnessProfile]:
    """``"cat=lever:value,...;cat2=..."`` → ``{category: profile}``; loud on junk."""
    profiles: dict[str, StrictnessProfile] = {}
    for entry in (raw or "").split(";"):
        entry = entry.strip()
        if not entry:
            continue
        if "=" not in entry:
            raise ValueError(
                f"strictness entry {entry!r}: expected 'category=lever:value,...'"
            )
        category, _, levers = entry.partition("=")
        category = category.strip().lower()
        if not category:
            raise ValueError(f"strictness entry {entry!r}: empty category")
        values: dict[str, float | int] = {}
        for lever in levers.split(","):
            lever = lever.strip()
            if not lever:
                continue
            name, sep, value = lever.partition(":")
            name = name.strip().lower()
            if not sep or name not in _LEVERS:
                raise ValueError(
                    f"strictness entry {entry!r}: lever {lever!r} is not one of {_LEVERS}"
                )
            try:
                values[name] = int(value) if name == "cap" else float(value)
            except ValueError as exc:
                raise ValueError(
                    f"strictness entry {entry!r}: {name} needs a number, got {value!r}"
                ) from exc
            if name != "cap" and not 0.0 < values[name] <= 1.0:
                raise ValueError(
                    f"strictness entry {entry!r}: {name} must be in (0, 1]"
                )
            if name == "cap" and values[name] < 1:
                raise ValueError(f"strictness entry {entry!r}: cap must be >= 1")
        if not values:
            raise ValueError(f"strictness entry {entry!r}: no levers given")
        if category in profiles:
            raise ValueError(f"strictness: category {category!r} given twice")
        profiles[category] = StrictnessProfile(**values)  # type: ignore[arg-type]
    return profiles


@dataclass(frozen=True)
class Strictness:
    """What `DedupStage` / `TopUpStage` consult per candidate (constructor-injected).

    ``answer_cap`` switches the repeated-answer cap on (ANSWER_CAP flag); the
    per-category ``cap`` values only matter when it is on. ``profiles`` may be
    empty — then every lever resolves to the global default it is asked with.
    """

    profiles: dict[str, StrictnessProfile]
    answer_cap: bool = False
    default_cap: int = ANSWER_CAP_DEFAULT

    def _profile(self, category: str | None) -> StrictnessProfile | None:
        if not category:
            return None
        return self.profiles.get(category.strip().lower())

    def cosine_for(self, category: str | None, default: float) -> float:
        profile = self._profile(category)
        return default if profile is None or profile.cosine is None else profile.cosine

    def in_batch_for(self, category: str | None, default: float) -> float:
        profile = self._profile(category)
        return (
            default if profile is None or profile.in_batch is None else profile.in_batch
        )

    def fact_for(self, category: str | None, default: float) -> float:
        profile = self._profile(category)
        return default if profile is None or profile.fact is None else profile.fact

    def cap_for(self, category: str | None) -> int:
        profile = self._profile(category)
        return (
            self.default_cap if profile is None or profile.cap is None else profile.cap
        )


NO_STRICTNESS = Strictness(profiles={})
