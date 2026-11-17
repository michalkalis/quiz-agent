"""#231 — Ukrainian as a fourth language, 231.2: the quality gates know uk.

Each test pins one uk branch and would fail without it. en/sk/cs behaviour is
pinned unchanged where a uk branch sits next to it.
"""

from __future__ import annotations

from datetime import date
from typing import Any

import pytest
from app import feature_flags, uk_policy
from app.corpus import fresh_topup
from app.corpus.fresh_brief import build_fresh_brief
from app.corpus.seed_filters import Seed, topic_policy_cut
from app.generation import prompt_builder
from app.generation.naturalness_check import NaturalnessChecker, needs_check
from app.scoring.machine_approval import (
    MACHINE_APPROVABLE_LANGUAGES,
    machine_approval_block_reason,
)
from app.translation_verification import answerability as tv_answerability
from app.translation_verification import judge
from app.translation_verification.draft import TranslatedDraft
from app.translation_verification.guards import (
    run_guards,
    script_integrity_reason,
)
from app.verification import answerability
from quiz_shared.models.question import Question

CLEAN_EXTRA = {
    "verified": True,
    "verification_score": 0.9,
    "factcheck_tier": "web",
}


def _q(**overrides: Any) -> Question:
    base: dict[str, Any] = {
        "id": "q_uk",
        "question": "Яка планета обертається швидше за всіх?",
        "correct_answer": "Юпітер",
        "topic": "Наука",
        "category": "science",
        "difficulty": "medium",
        "language": "uk",
        "source_url": "https://uk.wikipedia.org/wiki/Юпітер",
        "generation_metadata": {"extra": dict(CLEAN_EXTRA)},
    }
    base.update(overrides)
    return Question(**base)


# --- Russian contamination ------------------------------------------------


@pytest.mark.parametrize("text", ["Выбери ответ", "Це ъ", "Ёлка", "Это місто"])
def test_russian_only_letters_and_words_are_flagged(text: str) -> None:
    assert uk_policy.russian_contamination_reason([text]) is not None


def test_clean_ukrainian_text_is_not_flagged() -> None:
    assert (
        uk_policy.russian_contamination_reason(["Що це за місто? Київ, їжак"]) is None
    )


def test_translation_guard_blocks_russian_letters_in_uk_only() -> None:
    source = Question(
        id="s",
        question="What is the capital?",
        correct_answer="Kyiv",
        topic="Geo",
        category="geography",
        difficulty="easy",
    )
    draft = TranslatedDraft(question="Какая столица Украины?", correct_answer="Киев")
    assert any("russian" in r for r in run_guards(source, draft, "uk"))
    # the same letters in a Slovak draft are not this guard's business
    assert not any("russian" in r for r in run_guards(source, draft, "sk"))


def test_script_guard_lets_cyrillic_through_for_uk_but_not_sk() -> None:
    source = Question(
        id="s",
        question="What is the capital?",
        correct_answer="Kyiv",
        topic="Geo",
        category="geography",
        difficulty="easy",
    )
    draft = TranslatedDraft(question="Яка столиця України?", correct_answer="Київ")
    assert script_integrity_reason(source, draft, "uk") is None
    assert script_integrity_reason(source, draft, "sk") is not None


def test_script_guard_flags_a_latin_homoglyph_inside_a_ukrainian_word() -> None:
    source = Question(
        id="s",
        question="What is the capital?",
        correct_answer="Kyiv",
        topic="Geo",
        category="geography",
        difficulty="easy",
    )
    draft = TranslatedDraft(question="Яка столиця Украiни?", correct_answer="Київ")
    reason = script_integrity_reason(source, draft, "uk")
    assert reason is not None and "mixed script" in reason


# --- topic policy ---------------------------------------------------------


@pytest.mark.parametrize(
    "text",
    [
        "Хто очолює Росію?",
        "Коли почалося повномасштабне вторгнення?",
        "Яке місто було окуповане?",
        "Що таке Революція гідності?",
    ],
)
def test_topic_policy_flags_war_russia_and_politics(text: str) -> None:
    assert uk_policy.topic_policy_reason([text]) is not None


def test_topic_policy_leaves_history_culture_sport_alone() -> None:
    for text in ["Хто створив Щедрик?", "Який клуб виграв Кубок УЄФА?", "Зсув ґрунту"]:
        assert uk_policy.topic_policy_reason([text]) is None


def test_seed_filter_drops_policy_seeds_for_uk_only() -> None:
    def seeds() -> list[Seed]:
        return [
            Seed("Щедрик", "Колядка Леонтовича", "", "https://uk.wikipedia.org/a"),
            Seed("Фронт", "Вторгнення 2022 року", "", "https://uk.wikipedia.org/b"),
        ]

    dropped: dict[str, int] = {}
    kept = topic_policy_cut(seeds(), "uk", dropped)
    assert [s.subject for s in kept] == ["Щедрик"] and dropped == {"topic_policy": 1}
    assert len(topic_policy_cut(seeds(), "cs", {})) == 2


def test_machine_approval_holds_uk_rows_that_break_the_rules() -> None:
    assert "uk" in MACHINE_APPROVABLE_LANGUAGES
    assert machine_approval_block_reason(_q()) is None
    russian = machine_approval_block_reason(_q(question="Какая планета самая быстрая?"))
    assert russian and russian.startswith("uk_policy=russian")
    topic = machine_approval_block_reason(_q(question="Яка війна з Росією триває?"))
    assert topic and topic.startswith("uk_policy=topic_policy")


# --- prompts --------------------------------------------------------------


def test_uk_prompt_guards_against_russian_and_states_the_topic_rule() -> None:
    brief = prompt_builder.order_brief_section(None, "uk")
    assert "no Russian words or forms" in brief
    assert "Ukrainian" in brief and "Czech" not in brief
    assert uk_policy.UK_TOPIC_POLICY in brief
    assert '"Правда" / "Неправда"' in brief


def test_sk_prompt_is_unchanged_by_uk() -> None:
    brief = prompt_builder.order_brief_section(None, "sk")
    assert "no Czech words or forms" in brief
    assert "TOPIC POLICY" not in brief


def test_house_style_v2_uk_is_native_with_ukraine_as_home(monkeypatch) -> None:
    monkeypatch.setenv("GEN_HOUSE_STYLE_V2", "1")
    assert feature_flags.gen_house_style_v2()
    prompt_builder._house_style_v2_parts.cache_clear()
    lang_section, body = prompt_builder._house_style_v2_parts("uk")
    assert lang_section and "УКРАЇНСЬКА" in lang_section
    assert "РІДНА КРАЇНА: Гравці живуть в Україні" in body
    assert "Росія як тема" in body
    assert "## СТИЛЬ ДОМУ" in prompt_builder.house_style_section("uk")


def test_house_style_v2_uk_carries_the_native_speaker_phrasing_fixes(
    monkeypatch,
) -> None:
    """Native speaker 2026-11-17: the bookish "є + instrumental" copula and
    padding made 2 of 4 sample questions sound translated. The generator must
    see both the rule and the corrected examples."""
    monkeypatch.setenv("GEN_HOUSE_STYLE_V2", "1")
    prompt_builder._house_style_v2_parts.cache_clear()
    _, body = prompt_builder._house_style_v2_parts("uk")
    assert "«Яка столиця Австралії?»" in body
    assert "«Хто написав «Кобзар»?»" in body
    assert "Не будуй питання через «є» з орудним відмінком" in body


def test_house_style_v1_home_country_is_ukraine() -> None:
    assert prompt_builder._HOME_COUNTRY["uk"]["country"] == "Ukraine"


def test_fresh_brief_for_uk_has_ukraine_scene_and_topic_policy() -> None:
    brief = build_fresh_brief("uk", date(2026, 11, 17), [], [])
    assert "live in Ukraine" in brief and "Do not ask about the Russian scene" in brief
    assert uk_policy.UK_TOPIC_POLICY in brief
    assert uk_policy.UK_TOPIC_POLICY not in build_fresh_brief(
        "sk", date(2026, 11, 17), [], []
    )


# --- weekly job must not run uk ---------------------------------------------


def test_default_weekly_run_does_not_include_uk() -> None:
    assert "uk" not in fresh_topup.parse_args([]).languages
    assert "uk" not in fresh_topup.LANGUAGES


def test_uk_runs_only_when_named_explicitly() -> None:
    assert fresh_topup.parse_args(["--languages", "uk"]).languages == ["uk"]
    with pytest.raises(SystemExit):
        fresh_topup.parse_args(["--languages", "xx"])


def test_workflow_language_check_does_not_accept_uk() -> None:
    from pathlib import Path

    wf = Path(__file__).resolve().parents[3] / ".github/workflows/fresh-topup.yml"
    text = wf.read_text(encoding="utf-8")
    assert (
        "(en|sk|cs)(,(en|sk|cs))*" in text and "uk" not in text.split("LANGS:")[1][:400]
    )


# --- naturalness / answerability / translation verification ---------------


def test_naturalness_check_covers_uk_and_names_russian_as_neighbour() -> None:
    assert needs_check(_q())
    prompt = NaturalnessChecker._build_prompt([_q()])
    assert "native Ukrainian editor" in prompt and "ы э ъ ё" in prompt
    # The editor flags the copula calque the native speaker caught (2026-11-17).
    assert "Яка столиця Австралії?" in prompt
    assert "native Ukrainian editor" not in NaturalnessChecker._build_prompt(
        [_q(language="sk")]
    )


@pytest.mark.asyncio
async def test_naturalness_rewrite_with_russian_letters_is_dropped_but_cyrillic_ok() -> (
    None
):
    import json

    checker = NaturalnessChecker(model="claude-opus-5-5")
    good = {
        "index": 1,
        "ok": False,
        "problems": [{"kind": "calque", "quote": "x"}],
        "rewrite": "Яка планета обертається швидко?",
    }
    bad = dict(good, rewrite="Что за планета?")

    async def run(item: dict) -> Any:
        async def fake(prompt: str) -> str:
            return json.dumps({"checks": [item]})

        checker._complete = fake  # type: ignore[assignment]
        import app.generation.naturalness_check as nc

        nc.llm_factory.chat_available = lambda m: True  # type: ignore[assignment]
        return (await checker.check([_q()]))[0]

    assert (await run(good)) is not None
    assert (await run(bad)) is None


def test_inflected_language_answerability_includes_uk() -> None:
    assert "uk" in answerability._INFLECTED_LANGUAGES


@pytest.mark.asyncio
async def test_ukrainian_answer_with_another_ending_is_not_a_miss() -> None:
    question = _q(
        question="Яка фортеця в Хотині зведена на Дністрі?",
        correct_answer="Хотинська фортеця",
    )
    checker = answerability.AnswerabilityChecker(model="x")

    async def fake(prompt: str) -> str:
        return '{"answer": "Хотинської фортеці", "gave_up": false, "issue": null}'

    checker._complete = fake  # type: ignore[assignment]
    assert (await checker.check(question)).passed is True


def test_translation_stack_knows_uk() -> None:
    assert "uk" in tv_answerability._PROMPTS
    assert judge._NEIGHBOUR["uk"] == "Russian"
    assert judge._LANGUAGE_NAMES["uk"] == "Ukrainian"


def test_uk_glossary_loads_with_entries() -> None:
    entries = judge.load_glossary("uk")
    assert entries and all({"source", "target"} <= set(e) for e in entries)
    assert any(e["target"] == "Київ" for e in entries)
