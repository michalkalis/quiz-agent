"""Coverage for the typed `GenerationProvenance` sub-model and the new
Phase-1 optional fields on `Question` (issue #33 task 1.4).

Focus:
- Legacy free-form `generation_metadata` dict → `GenerationProvenance` is
  lossless (unknown keys land in `extra`).
- Round-trip through `model_dump()` / `model_dump_json()` preserves data.
- `get_ai_score()` reads the new typed `critique_score` first and falls
  back to legacy `extra["ai_score"]`.
- New top-level fields (`pack_id`, `language`, `prompt_seed`, `cost_cents`,
  `embedding_model`, `embedding_dim`) construct, dump, and re-parse cleanly.
"""

from __future__ import annotations

import json

import pytest

from quiz_shared.models.question import GenerationProvenance, Question


def _base_question(**overrides) -> dict:
    base = dict(
        id="q_test_001",
        question="What is 2+2?",
        correct_answer="4",
        topic="Math",
        category="adults",
        difficulty="easy",
    )
    base.update(overrides)
    return base


class TestGenerationProvenanceLegacyDict:
    def test_legacy_flat_dict_absorbs_unknown_keys_into_extra(self):
        legacy = {
            "model": "gpt-4o",
            "ai_score": 8.5,
            "ai_reasoning": "Sharp framing.",
            "self_critique": {"surprise_factor": 4, "overall_score": 8.5},
            "stage": "initial_generation",
        }

        prov = GenerationProvenance.model_validate(legacy)

        assert prov.model == "gpt-4o"
        assert prov.critique_score is None
        assert prov.extra["ai_score"] == 8.5
        assert prov.extra["ai_reasoning"] == "Sharp framing."
        assert prov.extra["self_critique"]["overall_score"] == 8.5
        assert prov.extra["stage"] == "initial_generation"

    def test_typed_keys_route_to_typed_fields_not_extra(self):
        payload = {
            "model": "claude-opus-4-7",
            "provider": "anthropic",
            "prompt_version": "v3_fact_first",
            "pipeline": "fact_first",
            "generation_temperature": 0.8,
            "critique_model": "gpt-4o-mini",
            "critique_score": 9.1,
            "fact_ids": ["f_001", "f_002"],
        }

        prov = GenerationProvenance.model_validate(payload)

        assert prov.model == "claude-opus-4-7"
        assert prov.provider == "anthropic"
        assert prov.prompt_version == "v3_fact_first"
        assert prov.pipeline == "fact_first"
        assert prov.generation_temperature == 0.8
        assert prov.critique_model == "gpt-4o-mini"
        assert prov.critique_score == 9.1
        assert prov.fact_ids == ["f_001", "f_002"]
        assert prov.extra == {}

    def test_legacy_dict_round_trips_losslessly_through_dump(self):
        legacy = {
            "model": "gpt-4o",
            "prompt_version": "v2_cot",
            "ai_score": 7.5,
            "weird_legacy_key": {"nested": "data"},
        }

        prov = GenerationProvenance.model_validate(legacy)
        dumped = prov.model_dump()
        re_parsed = GenerationProvenance.model_validate(dumped)

        assert re_parsed.model == "gpt-4o"
        assert re_parsed.prompt_version == "v2_cot"
        assert re_parsed.extra["ai_score"] == 7.5
        assert re_parsed.extra["weird_legacy_key"] == {"nested": "data"}

    def test_explicit_extra_field_merges_with_unknown_keys(self):
        payload = {
            "model": "gpt-4o",
            "extra": {"existing_key": 1},
            "another_unknown": 2,
        }

        prov = GenerationProvenance.model_validate(payload)

        assert prov.extra == {"existing_key": 1, "another_unknown": 2}


class TestQuestionWithProvenance:
    def test_question_constructor_coerces_dict_to_provenance(self):
        q = Question(
            **_base_question(
                generation_metadata={
                    "model": "gpt-4o",
                    "ai_score": 8.0,
                    "ai_reasoning": "ok",
                }
            )
        )

        assert isinstance(q.generation_metadata, GenerationProvenance)
        assert q.generation_metadata.model == "gpt-4o"
        assert q.generation_metadata.extra["ai_score"] == 8.0

    def test_get_ai_score_prefers_typed_critique_score(self):
        q = Question(
            **_base_question(
                generation_metadata={"critique_score": 9.0, "ai_score": 5.0},
            )
        )

        assert q.get_ai_score() == 9.0

    def test_get_ai_score_falls_back_to_extra_ai_score(self):
        q = Question(
            **_base_question(generation_metadata={"ai_score": 6.5})
        )

        assert q.get_ai_score() == 6.5

    def test_get_ai_score_returns_none_when_metadata_absent(self):
        q = Question(**_base_question())

        assert q.get_ai_score() is None

    def test_from_dict_preserves_legacy_self_critique_in_extra(self):
        legacy_payload = {
            "id": "q_legacy",
            "question": "What year did WWII end?",
            "correct_answer": "1945",
            "topic": "History",
            "category": "adults",
            "difficulty": "easy",
            "self_critique": {
                "surprise_factor": 3,
                "universal_appeal": 4,
                "clever_framing": 3,
                "educational_value": 4,
                "answerability": 5,
                "overall_score": 8.0,
                "reasoning": "Solid historical fact.",
            },
        }

        q = Question.from_dict(legacy_payload)

        assert isinstance(q.generation_metadata, GenerationProvenance)
        assert q.generation_metadata.extra["ai_score"] == 8.0
        assert q.generation_metadata.extra["ai_reasoning"] == "Solid historical fact."
        assert q.get_ai_score() == 8.0

    def test_provenance_serialises_to_json_for_chroma_storage(self):
        q = Question(
            **_base_question(
                generation_metadata=GenerationProvenance(
                    model="gpt-4o", critique_score=8.5, fact_ids=["f1"]
                )
            )
        )

        as_json = q.generation_metadata.model_dump_json()
        round_tripped = GenerationProvenance.model_validate(json.loads(as_json))

        assert round_tripped.model == "gpt-4o"
        assert round_tripped.critique_score == 8.5
        assert round_tripped.fact_ids == ["f1"]


class TestQuestionNewPhase1Fields:
    def test_new_optional_fields_default_to_none(self):
        q = Question(**_base_question())

        assert q.pack_id is None
        assert q.language is None
        assert q.prompt_seed is None
        assert q.embedding_model is None
        assert q.embedding_dim is None
        assert q.cost_cents is None

    def test_new_fields_construct_and_serialise(self):
        q = Question(
            **_base_question(
                pack_id="11111111-1111-1111-1111-111111111111",
                language="sk",
                prompt_seed="abcdef0123456789",
                embedding_model="text-embedding-3-small",
                embedding_dim=1536,
                cost_cents=42,
            )
        )

        dumped = q.model_dump()
        assert dumped["pack_id"] == "11111111-1111-1111-1111-111111111111"
        assert dumped["language"] == "sk"
        assert dumped["prompt_seed"] == "abcdef0123456789"
        assert dumped["embedding_model"] == "text-embedding-3-small"
        assert dumped["embedding_dim"] == 1536
        assert dumped["cost_cents"] == 42

    def test_new_fields_round_trip_through_json(self):
        q = Question(
            **_base_question(
                pack_id="pack-xyz",
                language="en",
                prompt_seed="seed_hash_001",
                cost_cents=15,
            )
        )

        re_parsed = Question.model_validate(json.loads(q.model_dump_json()))

        assert re_parsed.pack_id == "pack-xyz"
        assert re_parsed.language == "en"
        assert re_parsed.prompt_seed == "seed_hash_001"
        assert re_parsed.cost_cents == 15

    @pytest.mark.parametrize("language", ["en", "sk", "cs"])
    def test_language_accepts_supported_bcp47_codes(self, language: str):
        q = Question(**_base_question(language=language))
        assert q.language == language


class TestHeadlineAnswer:
    """Issue #46 D7 — open-branch ``headline_answer`` field."""

    def test_defaults_to_none_for_closed_questions(self):
        q = Question(**_base_question())
        assert q.headline_answer is None

    def test_constructs_and_round_trips_through_json(self):
        q = Question(
            **_base_question(
                question="Why are Ferraris red?",
                correct_answer="National racing colour",
                headline_answer="Italy's racing colour",
                explanation="Early Grand Prix assigned each nation a colour; Italy got red.",
            )
        )

        re_parsed = Question.model_validate(json.loads(q.model_dump_json()))
        assert re_parsed.headline_answer == "Italy's racing colour"

    def test_from_dict_carries_headline_answer(self):
        q = Question.from_dict(
            _base_question(
                headline_answer="Italy's racing colour",
            )
        )
        assert q.headline_answer == "Italy's racing colour"

    def test_from_dict_defaults_headline_answer_to_none(self):
        q = Question.from_dict(_base_question())
        assert q.headline_answer is None
