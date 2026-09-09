"""Tests for `scripts/propose_subtopics.py` (#170 task 170.1, decision D4).

Why these tests matter:
- The proposal file is a **founder hand-off** (locked 5): the founder reads
  it once, edits it, and Session B freezes it into ``app/generation/
  subtopics.json``. A file that is schema-valid but silently missing a
  category, or carrying an id the taxonomy does not know, would be frozen
  into the runtime unnoticed — so every such case must exit 1 and write
  nothing, never a partial file.
- ``questions.subtopic`` is ``VARCHAR(64)`` (D8): a longer name would fail
  at the first steered persist, weeks after the founder approved it.

No network: the structured LLM call is replaced by a fake in every test.
"""

from __future__ import annotations

import json

import pytest
import scripts.propose_subtopics as ps
from app.generation.classification import CATEGORIES


def _names(prefix: str, n: int = 15) -> list[str]:
    return [f"{prefix} subtopic {i}" for i in range(n)]


def _fake_proposer(answers: dict[str, ps.SubtopicProposal]):
    """Return a `propose_category` double that records which ids were asked for."""
    asked: list[str] = []

    async def fake(llm, category, target=ps.DEFAULT_TARGET, **kwargs):
        asked.append(category)
        return answers[category]

    return fake, asked


class TestHappyPath:
    def test_writes_schema_valid_proposal(self, tmp_path, monkeypatch):
        answers = {
            "general": ps.SubtopicProposal(
                category="general", subtopics=_names("general")
            ),
            "kids": ps.SubtopicProposal(category="kids", subtopics=_names("kids", 20)),
        }
        fake, asked = _fake_proposer(answers)
        monkeypatch.setattr(ps, "propose_category", fake)
        monkeypatch.setattr(ps, "_build_llm", lambda model: object())
        out = tmp_path / "proposal.json"

        assert ps.main(["--out", str(out), "--categories", "general,kids"]) == 0

        payload = json.loads(out.read_text())
        # Three levels: language → category → list of strings (D4 schema).
        assert list(payload) == ["en"]
        assert set(payload["en"]) == {"general", "kids"}
        for subtopics in payload["en"].values():
            assert subtopics and all(isinstance(s, str) for s in subtopics)
            assert len({s.lower() for s in subtopics}) == len(subtopics)
        assert sorted(asked) == ["general", "kids"]

    def test_default_categories_are_the_whole_taxonomy(self, tmp_path, monkeypatch):
        """Locked 5: the proposal covers every id in CATEGORIES unless overridden."""
        answers = {
            c: ps.SubtopicProposal(category=c, subtopics=_names(c)) for c in CATEGORIES
        }
        fake, asked = _fake_proposer(answers)
        monkeypatch.setattr(ps, "propose_category", fake)
        monkeypatch.setattr(ps, "_build_llm", lambda model: object())
        out = tmp_path / "proposal.json"

        assert ps.main(["--out", str(out)]) == 0
        assert sorted(asked) == sorted(CATEGORIES)
        assert set(json.loads(out.read_text())["en"]) == set(CATEGORIES)

    def test_structured_output_path_is_exercised(self, tmp_path, monkeypatch):
        """The real code path: `with_structured_output(...).ainvoke` → parsed model."""

        class _Structured:
            def __init__(self, category):
                self.category = category

            async def ainvoke(self, messages):
                # The category id must reach the prompt, or the model cannot echo it.
                assert any(self.category in m.content for m in messages)
                return {
                    "raw": None,
                    "parsed": ps.SubtopicProposal(
                        category=self.category, subtopics=_names(self.category)
                    ),
                    "parsing_error": None,
                }

        class _FakeLLM:
            def with_structured_output(self, schema, **kwargs):
                assert schema is ps.SubtopicProposal
                assert kwargs == {"method": "function_calling", "include_raw": True}
                return _Dispatcher()

        class _Dispatcher:
            async def ainvoke(self, messages):
                category = messages[-1].content.split("`")[1]
                return await _Structured(category).ainvoke(messages)

        monkeypatch.setattr(ps, "_build_llm", lambda model: _FakeLLM())
        out = tmp_path / "proposal.json"

        assert ps.main(["--out", str(out), "--categories", "general"]) == 0
        assert json.loads(out.read_text()) == {"en": {"general": _names("general")}}


class TestFailLoud:
    """Every rejection exits 1 and leaves no file behind."""

    def _run(self, tmp_path, monkeypatch, answers, categories="general,kids"):
        fake, _ = _fake_proposer(answers)
        monkeypatch.setattr(ps, "propose_category", fake)
        monkeypatch.setattr(ps, "_build_llm", lambda model: object())
        out = tmp_path / "proposal.json"
        code = ps.main(["--out", str(out), "--categories", categories])
        return code, out.exists()

    def test_invented_category_exits_1(self, tmp_path, monkeypatch):
        """Intent: the proposal is never silently trimmed to a subset of the
        taxonomy — an id the model made up cannot be filed under a real one."""
        answers = {
            "general": ps.SubtopicProposal(
                category="trivia", subtopics=_names("general")
            ),
            "kids": ps.SubtopicProposal(category="kids", subtopics=_names("kids")),
        }
        assert self._run(tmp_path, monkeypatch, answers) == (1, False)

    def test_failed_category_call_writes_no_partial_file(self, tmp_path, monkeypatch):
        async def fake(llm, category, target=ps.DEFAULT_TARGET, **kwargs):
            if category == "kids":
                raise RuntimeError("claude -p exited 1")
            return ps.SubtopicProposal(category=category, subtopics=_names(category))

        monkeypatch.setattr(ps, "propose_category", fake)
        monkeypatch.setattr(ps, "_build_llm", lambda model: object())
        out = tmp_path / "proposal.json"
        assert ps.main(["--out", str(out), "--categories", "general,kids"]) == 1
        assert not out.exists()

    def test_no_structured_output_exits_1(self, tmp_path, monkeypatch):
        class _FakeLLM:
            def with_structured_output(self, schema, **kwargs):
                return self

            async def ainvoke(self, messages):
                return {"raw": None, "parsed": None, "parsing_error": "no tool call"}

        monkeypatch.setattr(ps, "_build_llm", lambda model: _FakeLLM())
        out = tmp_path / "proposal.json"
        assert ps.main(["--out", str(out), "--categories", "general"]) == 1
        assert not out.exists()

    def test_duplicate_subtopics_exit_1(self, tmp_path, monkeypatch):
        dupes = _names("general", 14) + ["Space exploration", "  space  EXPLORATION "]
        answers = {
            "general": ps.SubtopicProposal(category="general", subtopics=dupes),
            "kids": ps.SubtopicProposal(category="kids", subtopics=_names("kids")),
        }
        assert self._run(tmp_path, monkeypatch, answers) == (1, False)

    def test_too_long_subtopic_exits_1(self, tmp_path, monkeypatch):
        """`questions.subtopic` is VARCHAR(64) (D8) — reject before the founder approves it."""
        too_long = "x" * (ps.MAX_SUBTOPIC_CHARS + 1)
        answers = {
            "general": ps.SubtopicProposal(
                category="general", subtopics=_names("general", 14) + [too_long]
            ),
            "kids": ps.SubtopicProposal(category="kids", subtopics=_names("kids")),
        }
        assert self._run(tmp_path, monkeypatch, answers) == (1, False)

    def test_too_few_subtopics_exit_1(self, tmp_path, monkeypatch):
        """Session B's loader test (A1) needs >= 10 per category."""
        answers = {
            "general": ps.SubtopicProposal(
                category="general", subtopics=_names("general", 3)
            ),
            "kids": ps.SubtopicProposal(category="kids", subtopics=_names("kids")),
        }
        assert self._run(tmp_path, monkeypatch, answers) == (1, False)


class TestValidateProposal:
    """Direct checks on the validator Session B can reuse."""

    def test_missing_category_is_rejected(self):
        payload = {"en": {"general": _names("general")}}
        with pytest.raises(ps.ProposalError, match="missing"):
            ps.validate_proposal(payload, language="en", categories=["general", "kids"])

    def test_extra_category_is_rejected(self):
        payload = {"en": {"general": _names("general"), "trivia": _names("trivia")}}
        with pytest.raises(ps.ProposalError, match="outside the taxonomy"):
            ps.validate_proposal(payload, language="en", categories=["general"])

    def test_wrong_language_key_is_rejected(self):
        payload = {"sk": {"general": _names("general")}}
        with pytest.raises(ps.ProposalError, match="top level"):
            ps.validate_proposal(payload, language="en", categories=["general"])

    def test_clean_payload_passes(self):
        payload = {"en": {"general": _names("general"), "kids": _names("kids", 20)}}
        ps.validate_proposal(payload, language="en", categories=["general", "kids"])

    def test_topup_appends_additions_after_approved_list(self, tmp_path, monkeypatch):
        """Gate F1 follow-up: the founder approved a list and asked for more of a
        flavour. Approved names must survive untouched and first; additions
        follow; an echo of an approved name is dropped, not a failure."""
        approved = {"en": {"general": _names("approved", 12)}}
        existing = tmp_path / "approved.json"
        existing.write_text(json.dumps(approved))
        seen_prompts: list[str] = []

        async def fake(
            llm, category, target=ps.DEFAULT_TARGET, *, existing=None, guidance=None
        ):
            seen_prompts.append(
                ps.build_messages(
                    category, target, existing=existing, guidance=guidance
                )[-1].content
            )
            assert existing == approved["en"]["general"]
            return ps.SubtopicProposal(
                category=category,
                subtopics=[
                    "Everyday brands and slogans",
                    "APPROVED subtopic 3",
                    "Phobias and superstitions",
                ],
            )

        monkeypatch.setattr(ps, "propose_category", fake)
        monkeypatch.setattr(ps, "_build_llm", lambda model: object())
        out = tmp_path / "topup.json"

        code = ps.main(
            [
                "--out",
                str(out),
                "--categories",
                "general",
                "--existing",
                str(existing),
                "--guidance",
                "more everyday themes",
                "--target",
                "3",
            ]
        )
        assert code == 0
        result = json.loads(out.read_text())["en"]["general"]
        assert result[:12] == approved["en"]["general"]
        assert result[12:] == [
            "Everyday brands and slogans",
            "Phobias and superstitions",
        ]
        assert "more everyday themes" in seen_prompts[0]
        assert "approved subtopic 0" in seen_prompts[0]

    def test_topup_refuses_category_missing_from_approved_file(
        self, tmp_path, monkeypatch
    ):
        """A top-up never silently starts a category from scratch."""
        existing = tmp_path / "approved.json"
        existing.write_text(json.dumps({"en": {"general": _names("approved", 12)}}))
        called = []

        async def fake(
            llm, category, target=ps.DEFAULT_TARGET, *, existing=None, guidance=None
        ):
            called.append(category)
            return ps.SubtopicProposal(category=category, subtopics=_names(category))

        monkeypatch.setattr(ps, "propose_category", fake)
        monkeypatch.setattr(ps, "_build_llm", lambda model: object())
        out = tmp_path / "topup.json"
        code = ps.main(
            [
                "--out",
                str(out),
                "--categories",
                "general,kids",
                "--existing",
                str(existing),
            ]
        )
        assert code == 1
        assert not out.exists()
        assert called == []

    def test_every_brief_fits_in_prompt_for_known_ids(self):
        """Both taxonomies (generation CATEGORIES + the app's interest ids) have a brief,
        so the model never has to guess what an id means."""
        for category in CATEGORIES:
            assert category in ps.CATEGORY_BRIEFS
        for category in (
            "science-nature",
            "history",
            "geography-world",
            "movies-music",
            "sports",
            "food-everyday",
        ):
            assert category in ps.CATEGORY_BRIEFS
