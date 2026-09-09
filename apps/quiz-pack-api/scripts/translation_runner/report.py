"""``report --coverage`` and ``reconcile`` (T17, DD1, DD4).

Coverage counts SERVING-ELIGIBLE rows (no pack, ``approved``, not
``language_dependent``) per cell of the retrieval shape — 6 categories × 3
difficulties — for English and for the target language
(``approved_languages @> {lang}``). Three bars, all required; the constants are
retrieval-derived defaults (HG-4: the founder confirms or adjusts them), so
they are named and CLI-overridable, never lowered to make a bar pass.

The TestFlight channel (``approved`` + ``pending_review``) is reported
alongside and never relaxes a bar. Waivers are per run, recorded verbatim in
the run-report JSON, never persisted as config.
"""

from __future__ import annotations

import json
import math
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime
from pathlib import Path

from quiz_shared.database.pgvector_client import questions_table
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncEngine

#: `admin.CATEGORY_TAXONOMY` (quiz-agent) — 6 interest categories; the quiz
#: picker mirrors this list, so the crosstab is the picker's shape.
CATEGORIES: tuple[str, ...] = (
    "science-nature",
    "history",
    "geography-world",
    "movies-music",
    "sports",
    "food-everyday",
)
DIFFICULTIES: tuple[str, ...] = ("easy", "medium", "hard")

CELL_FLOOR = 10  # bar 2: translated rows per cell
CELL_RATIO = 0.95  # bar 1: translated / EN per cell
CATEGORY_FLOOR = 30  # bar 3: min(30, ceil(0.95 × eligible EN))
REPORTS_DIR = Path("data/translation_reports")


@dataclass
class Cell:
    category: str
    difficulty: str
    en: int
    translated: int
    en_starved: bool = False
    failing: list[str] = field(default_factory=list)
    waived: str | None = None

    @property
    def ratio(self) -> float:
        return self.translated / self.en if self.en else 1.0


@dataclass
class CategoryRow:
    category: str
    en: int
    translated: int
    floor: int
    en_starved_category: bool = False
    failing: bool = False
    waived: str | None = None


@dataclass
class CoverageReport:
    language: str
    cells: list[Cell]
    categories: list[CategoryRow]
    missing_qids: list[str]
    testflight: dict[str, int]
    constants: dict[str, float]
    waivers: list[dict[str, str]]

    @property
    def ok(self) -> bool:
        return not any(c.failing and not c.waived for c in self.cells) and not any(
            r.failing and not r.waived for r in self.categories
        )


def evaluate(
    en: dict[tuple[str, str], int],
    translated: dict[tuple[str, str], int],
    *,
    cell_floor: int = CELL_FLOOR,
    cell_ratio: float = CELL_RATIO,
    category_floor: int = CATEGORY_FLOOR,
    waivers: dict[str, str] | None = None,
) -> tuple[list[Cell], list[CategoryRow]]:
    """Apply the three bars to per-cell counts. Pure — the DB part is elsewhere."""
    waivers = waivers or {}
    # The taxonomy first, then anything else the corpus carries (e.g. `general`
    # from #170's no-category mode) so no eligible row hides from the crosstab.
    extra = sorted({c for c, _ in (*en, *translated)} - set(CATEGORIES))
    categories = (*CATEGORIES, *extra)
    cells: list[Cell] = []
    for cat in categories:
        for diff in DIFFICULTIES:
            c = Cell(cat, diff, en.get((cat, diff), 0), translated.get((cat, diff), 0))
            if c.en < cell_floor:
                c.en_starved = True  # excluded from bars 1–2
            else:
                if c.ratio < cell_ratio:
                    c.failing.append("ratio")
                if c.translated < cell_floor:
                    c.failing.append("cell_floor")
            c.waived = waivers.get(f"{cat}/{diff}") or waivers.get(cat)
            cells.append(c)
    rows: list[CategoryRow] = []
    for cat in categories:
        en_cat = sum(c.en for c in cells if c.category == cat)
        tr_cat = sum(c.translated for c in cells if c.category == cat)
        floor = min(category_floor, math.ceil(cell_ratio * en_cat))
        r = CategoryRow(
            cat, en_cat, tr_cat, floor, en_starved_category=en_cat < category_floor
        )
        r.failing = tr_cat < floor
        r.waived = waivers.get(cat)
        rows.append(r)
    return cells, rows


async def _cell_counts(
    engine: AsyncEngine, statuses: list[str], language: str | None
) -> dict[tuple[str, str], int]:
    t = questions_table
    stmt = (
        select(t.c.category, t.c.difficulty, func.count())
        .where(
            t.c.pack_id.is_(None),
            t.c.language_dependent.is_(False),
            t.c.review_status.in_(statuses),
            (t.c.language.is_(None)) | (t.c.language == "en"),
        )
        .group_by(t.c.category, t.c.difficulty)
    )
    if language:
        stmt = stmt.where(t.c.approved_languages.contains([language]))
    async with engine.connect() as conn:
        rows = (await conn.execute(stmt)).all()
    return {(cat, diff): n for cat, diff, n in rows}


async def _missing_qids(engine: AsyncEngine, language: str) -> list[str]:
    t = questions_table
    stmt = select(t.c.id).where(
        t.c.pack_id.is_(None),
        t.c.language_dependent.is_(False),
        t.c.review_status == "approved",
        (t.c.language.is_(None)) | (t.c.language == "en"),
        ~t.c.approved_languages.contains([language]),
    )
    async with engine.connect() as conn:
        return [str(r[0]) for r in (await conn.execute(stmt)).all()]


async def coverage(
    engine: AsyncEngine,
    language: str,
    *,
    cell_floor: int = CELL_FLOOR,
    cell_ratio: float = CELL_RATIO,
    category_floor: int = CATEGORY_FLOOR,
    waivers: dict[str, str] | None = None,
) -> CoverageReport:
    en = await _cell_counts(engine, ["approved"], None)
    tr = await _cell_counts(engine, ["approved"], language)
    tf_en = await _cell_counts(engine, ["approved", "pending_review"], None)
    tf_tr = await _cell_counts(engine, ["approved", "pending_review"], language)
    cells, rows = evaluate(
        en,
        tr,
        cell_floor=cell_floor,
        cell_ratio=cell_ratio,
        category_floor=category_floor,
        waivers=waivers,
    )
    return CoverageReport(
        language=language,
        cells=cells,
        categories=rows,
        missing_qids=await _missing_qids(engine, language),
        testflight={"en": sum(tf_en.values()), "translated": sum(tf_tr.values())},
        constants={
            "cell_floor": cell_floor,
            "cell_ratio": cell_ratio,
            "category_floor": category_floor,
        },
        waivers=[{"target": k, "reason": v} for k, v in (waivers or {}).items()],
    )


def render(report: CoverageReport) -> str:
    lines = [
        (
            f"coverage --language {report.language}  (approved-only, binding; "
            f"TestFlight channel: {report.testflight['translated']}/{report.testflight['en']})"
        ),
        f"{'category':<18}{'difficulty':<10}{'en':>5}{'tr':>5}{'ratio':>7}  status",
    ]
    for c in report.cells:
        status = (
            "en_starved"
            if c.en_starved
            else ("FAIL " + ",".join(c.failing) if c.failing else "ok")
        )
        if c.failing and c.waived:
            status = f"WAIVED ({c.waived})"
        lines.append(
            f"{c.category:<18}{c.difficulty:<10}{c.en:>5}{c.translated:>5}{c.ratio:>7.2f}  {status}"
        )
    lines.append("")
    for r in report.categories:
        status = (
            "ok"
            if not r.failing
            else (f"WAIVED ({r.waived})" if r.waived else "FAIL category_floor")
        )
        starved = "  en_starved_category" if r.en_starved_category else ""
        lines.append(
            f"{r.category:<18}{'(all)':<10}{r.en:>5}{r.translated:>5}  floor {r.floor}  {status}{starved}"
        )
    lines.append("")
    lines.append(
        f"untranslated eligible EN rows: {len(report.missing_qids)} "
        f"(= the next `submit --limit` work set)"
    )
    lines.append("RESULT: " + ("PASS" if report.ok else "FAIL"))
    return "\n".join(lines)


def write_run_report(report: CoverageReport, out_dir: Path = REPORTS_DIR) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%S")
    path = out_dir / f"coverage-{report.language}-{stamp}.json"
    payload = {
        "generated_at": datetime.now(UTC).isoformat(),
        "ok": report.ok,
        **{k: v for k, v in asdict(report).items()},
    }
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return path
