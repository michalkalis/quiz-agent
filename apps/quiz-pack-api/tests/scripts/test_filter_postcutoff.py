"""Tests for `scripts/filter_postcutoff.py` (issue #167, task 167.6).

Why these tests matter: the pilot generates *post-cutoff settled facts*, which
the expiry classifier labels `evergreen` → `freshness_tag = NULL`,
indistinguishable from a genuinely timeless row and from a classifier fail-safe
(D1). This filter is therefore the ONLY gate that measures the defining
property of the question class; if its predicate is wrong, nothing downstream
catches it.

The excerpt leg is best-effort by construction: a row whose model-emitted
`source_url` is absent from the fact file loses the excerpt and falls back to
its own text. That is an ACCEPTED degradation (D6) — asserted here so a future
reader does not "fix" it into a hard failure.
"""

from __future__ import annotations

import json
from pathlib import Path

from quiz_shared.models.question import Question

from scripts import filter_postcutoff


def _row(**overrides) -> dict:
    """A `generate_pack.py --out` row: a full `Question.model_dump` dict."""
    data = {
        "id": "q-167-fixture",
        "question": "Who produced the 2026 debut album of Nova Reyes?",
        "type": "text",
        "correct_answer": "Jonas Vale",
        "topic": "Entertainment",
        "category": "entertainment",
        "difficulty": "medium",
        "source_url": "https://example.com/producers-2026",
        "review_status": "pending_review",
    }
    data.update(overrides)
    # Round-trips through the shared model so a fixture that the filter could
    # never receive in production fails here rather than passing vacuously.
    return Question.model_validate(data).model_dump(mode="json")


def _write(path: Path, payload) -> Path:
    path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    return path


def _facts_file(tmp_path: Path, *facts) -> Path:
    return _write(
        tmp_path / "facts.json",
        {"topics": ["2026 album releases"], "facts": list(facts)},
    )


def _run(tmp_path: Path, rows, *extra_args) -> tuple[list[dict], list[dict]]:
    batch = _write(tmp_path / "pilot_167.json", rows)
    assert filter_postcutoff.main([str(batch), *extra_args]) == 0
    accepted = json.loads((tmp_path / "pilot_167_accepted.json").read_text())
    rejected = json.loads((tmp_path / "pilot_167_rejected.json").read_text())
    return accepted, rejected


class TestPostCutoffPredicate:
    """167.6 — the only gate that can measure "post-cutoff" (D1)."""

    def test_accepts_year_token_in_question(self, tmp_path: Path):
        accepted, rejected = _run(tmp_path, [_row(id="q-in-question")])
        assert [r["id"] for r in accepted] == ["q-in-question"]
        assert rejected == []

    def test_accepts_year_token_in_answer(self, tmp_path: Path):
        # The stem is timeless; the answer is what dates the fact.
        row = _row(
            id="q-in-answer",
            question="Which album did Nova Reyes release first?",
            correct_answer="Ember Tide (2026)",
        )
        accepted, _ = _run(tmp_path, [row])
        assert [r["id"] for r in accepted] == ["q-in-answer"]

    def test_accepts_year_token_in_mcq_option_text(self, tmp_path: Path):
        # MCQ rows store the bare option key; a lone "b" carries no year, so the
        # option text has to be resolved or every MCQ row would be rejected.
        row = _row(
            id="q-mcq",
            question="Which album did Nova Reyes release first?",
            type="text_multichoice",
            possible_answers={"a": "Glass Harbour (2019)", "b": "Ember Tide (2026)"},
            correct_answer="b",
        )
        accepted, _ = _run(tmp_path, [row])
        assert [r["id"] for r in accepted] == ["q-mcq"]

    def test_accepts_via_offline_joined_excerpt(self, tmp_path: Path):
        # Neither stem nor answer names the year — only the fact the row came
        # from does, and it is joined offline by normalized source_url.
        row = _row(
            id="q-via-excerpt",
            question="Which album did Nova Reyes release first?",
            correct_answer="Ember Tide",
            source_url="https://WWW.example.com/producers-2026/",
        )
        facts = _facts_file(
            tmp_path,
            {
                "text": "Nova Reyes debut",
                "source_url": "http://example.com/producers-2026",
                "excerpt": "Ember Tide arrived in March 2026 to strong reviews.",
            },
        )
        accepted, rejected = _run(tmp_path, [row], "--facts-file", str(facts))
        assert [r["id"] for r in accepted] == ["q-via-excerpt"]
        assert rejected == []

    def test_rejects_row_without_any_year_token(self, tmp_path: Path):
        row = _row(
            id="q-no-year",
            question="Which album did Nova Reyes release first?",
            correct_answer="Ember Tide",
        )
        facts = _facts_file(
            tmp_path,
            {
                "text": "Nova Reyes debut",
                "source_url": "https://example.com/producers-2026",
                "excerpt": "Ember Tide followed a 2019 mixtape.",
            },
        )
        accepted, rejected = _run(tmp_path, [row], "--facts-file", str(facts))
        assert accepted == []
        assert [(r["id"], r["reason"]) for r in rejected] == [
            ("q-no-year", "no_2026_token")
        ]

    def test_rejects_freshness_current_even_with_year_token(self, tmp_path: Path):
        # A "current" row is the news class this pilot deliberately excludes
        # (founder decision 1), however well it scores on the year leg.
        row = _row(id="q-current", freshness_tag="current")
        accepted, rejected = _run(tmp_path, [row])
        assert accepted == []
        assert [(r["id"], r["reason"]) for r in rejected] == [
            ("q-current", "freshness_current")
        ]

    def test_url_missing_from_fact_file_falls_back_to_row_text(self, tmp_path: Path):
        # ACCEPTED degradation (D6): when the model emitted its own URL, the
        # offline join misses and only the row's own text can carry the year.
        # Asserted, not treated as a bug — both directions.
        kept = _row(id="q-unjoined-dated", source_url="https://model-emitted.test/a")
        dropped = _row(
            id="q-unjoined-undated",
            question="Which album did Nova Reyes release first?",
            correct_answer="Ember Tide",
            source_url="https://model-emitted.test/b",
        )
        facts = _facts_file(
            tmp_path,
            {
                "text": "unrelated",
                "source_url": "https://example.com/producers-2026",
                "excerpt": "A 2026 release calendar.",
            },
        )
        accepted, rejected = _run(tmp_path, [kept, dropped], "--facts-file", str(facts))
        assert [r["id"] for r in accepted] == ["q-unjoined-dated"]
        assert [(r["id"], r["reason"]) for r in rejected] == [
            ("q-unjoined-undated", "no_2026_token")
        ]

    def test_writes_both_files_and_prints_tally(self, tmp_path: Path, capsys):
        rows = [_row(id="q-ok"), _row(id="q-current", freshness_tag="current")]
        accepted, rejected = _run(tmp_path, rows)
        out = capsys.readouterr().out
        assert "accepted:          1" in out
        assert "freshness_current: 1" in out
        # Accepted rows stay byte-identical to the input: the rating page and
        # the importer read this file directly, so no extra keys.
        assert accepted == [rows[0]]
        assert "reason" not in accepted[0]
        assert rejected[0]["reason"] == "freshness_current"
