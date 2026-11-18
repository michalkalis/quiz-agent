"""#231 — Ukrainian as a fourth language: holes an independent review found
in the uk gates (2026-11-18).

Why these matter: 185 Ukrainian rows were machine-approved, and machine
approval is what lets a row reach App Store players with nobody reading it.
Founder rules for uk: no war since 2014, no current politics, no relations
with Russia (not even heroic); history, culture and sport before that are
welcome; no Russian letters or words. Every string below is one the old gates
let through (or wrongly killed). en/sk/cs must behave exactly as before.
"""

from __future__ import annotations

from typing import Any

import pytest
from app import uk_policy
from app.corpus.seed_filters import Seed, topic_policy_cut
from app.scoring import craft_guards
from app.scoring.machine_approval import GATE_VERSION, machine_approval_block_reason
from app.translation_verification.normalize import covers_tokens, fold
from app.verification.answerability import _text_answers_match
from quiz_shared.models.question import Question
from quiz_shared.utils.text_normalization import normalize_text

CLEAN_EXTRA = {
    "verified": True,
    "verification_score": 0.9,
    "factcheck_tier": "web",
    "naturalness": {"ok": True},
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


def test_the_clean_baseline_row_is_approved() -> None:
    """Every test below changes one field of this row; it must start clean."""
    assert machine_approval_block_reason(_q()) is None


# --- 1. war and politics wording must never be machine-approved -------------

WAR_AND_POLITICS = [
    "Яке місто 2022 року пережило облогу «Азовсталі»?",
    "Який півострів 2014 року опинився під контролем іншої держави?",
    "Яке місто на Донбасі звільнили восени 2022 року?",
    "Як називається війна, що почалася 24 лютого?",
    "Хто став президентом України 2019 року?",
    "РФ напала на Україну. Яке це місто?",
    "Що сталося на Майдані взимку 2014?",
    "Як називають події, відомі як Революція гідності?",
    "Чим завершилася Революції гідності перша ніч?",
    "Що почалося з Революцією гідності?",
    "Яку подію називають Революцію гідності?",
    "Де «Мрію» знищили в Гостомелі?",
    "Хто влучив по крейсеру «Москва»?",
]


@pytest.mark.parametrize("text", WAR_AND_POLITICS)
def test_war_and_current_politics_are_never_machine_approved(text: str) -> None:
    reason = machine_approval_block_reason(_q(question=text))
    assert reason and reason.startswith("uk_policy=topic_policy")


def test_a_comparison_with_moscow_in_the_explanation_is_held() -> None:
    # Russia "as a comparison" is still Russia as a topic.
    row = _q(
        question="Яка станція київського метро найглибша?",
        correct_answer="Арсенальна",
        explanation="Вона глибша за найглибшими станціями Москви.",
    )
    assert "topic_policy:hold" in (machine_approval_block_reason(row) or "")


@pytest.mark.parametrize(
    "text",
    [
        "Яке місто 2022 року пережило облогу «Азовсталі»?",
        "Яке місто на Донбасі звільнили восени 2022 року?",
        "РФ напала на Україну.",
        "Що таке Революцією гідності?",
    ],
)
def test_unambiguous_modern_war_wording_is_rejected_not_just_held(text: str) -> None:
    assert uk_policy.topic_reject_reason([text]) is not None


# --- 2. legitimate content: clean, or held for a human, never killed --------


@pytest.mark.parametrize(
    "text",
    ["Що блищить на росі вранці?", "На Росі стоїть Біла Церква.", "Чим пояснюють агресія у тварин?"],
)
def test_dew_the_river_ros_and_animal_aggression_are_plain_words(text: str) -> None:
    assert uk_policy.topic_policy_reason([text]) is None
    assert machine_approval_block_reason(_q(question=text)) is None


HISTORY = [
    "Після монгольського вторгнення 1240 року який місто занепало?",
    "Під час німецької окупації Києва 1941 року що зруйнували?",
    "Шевченко жив у Російській імперії. Де він навчався?",
    "Яка була анексія Криму Російською імперією 1783 року?",
]


@pytest.mark.parametrize("text", HISTORY)
def test_history_before_2014_is_held_for_a_human_not_rejected(text: str) -> None:
    """Pre-2014 history is welcome, but a keyword cannot tell 1240 from 2022:
    a human decides (pending_review = TestFlight-only), nothing is lost."""
    assert uk_policy.topic_reject_reason([text]) is None
    reason = machine_approval_block_reason(_q(question=text))
    assert reason and reason.startswith("uk_policy=topic_policy:hold(")


def test_held_seeds_are_kept_and_only_rejects_are_dropped() -> None:
    seeds = [Seed(f"s{i}", text, "", f"https://uk.wikipedia.org/{i}") for i, text in enumerate(HISTORY)]
    seeds.append(Seed("dew", "Роса на росі", "", "https://uk.wikipedia.org/d"))
    seeds.append(Seed("war", "Облога Азовсталі 2022 року", "", "https://uk.wikipedia.org/w"))
    dropped: dict[str, int] = {}
    kept = topic_policy_cut(seeds, "uk", dropped)
    assert [s.subject for s in kept] == ["s0", "s1", "s2", "s3", "dew"]
    assert dropped == {"topic_policy": 1}


# --- 3. Russian text, surzhyk and Russian name forms ------------------------

RUSSIAN = [
    "Какой город столица Франции?",
    "В каком году родился Шевченко?",
    "Он жил в городе Харьков",
    "Шо це за місто? Канєшно Київ",
    "Тіпа вісімнадцять",
]
RUSSIAN_NAMES = ["Киев", "Харьков", "Одесса", "Львов", "Днепр", "Вена", "Запорожье", "Запорожжя", "Борщев", "Меланин"]


@pytest.mark.parametrize("text", RUSSIAN + RUSSIAN_NAMES)
def test_russian_and_surzhyk_are_caught(text: str) -> None:
    assert uk_policy.russian_contamination_reason([text]) is not None


@pytest.mark.parametrize("name", RUSSIAN_NAMES)
def test_a_russian_name_form_in_an_accepted_answer_is_held(name: str) -> None:
    # An accepted alternative is what the voice grader takes as right.
    reason = machine_approval_block_reason(_q(alternative_answers=[name]))
    assert reason and reason.startswith("uk_policy=russian")


def test_a_long_text_without_any_ukrainian_letter_is_held() -> None:
    # Russian with none of the listed letters or words: only the missing
    # і/ї/є/ґ gives it away.
    russian = (
        "Капелька летнего дождя прилетает к мальчику Вове, вместе путешествуют "
        "по городу, видят радугу и смеются над облаками"
    )
    assert uk_policy.russian_contamination_reason([russian]) == "russian_text(no і/ї/є/ґ)"


@pytest.mark.parametrize(
    "text",
    [
        "Перший пасажирський потяг прибув з Перемишля до Львова 4 листопада 1861 року о 14:30.",
        "Яка золота жила була в Карпатах?",
        "Яка вена несе кров до серця? Порожниста вена",
        "Звідки родом запорожець Сірко?",
        "Що це за місто? Київ, їжак",
    ],
)
def test_real_ukrainian_is_not_mistaken_for_russian(text: str) -> None:
    assert uk_policy.russian_contamination_reason([text]) is None


# --- 5. the source and every text field --------------------------------------


@pytest.mark.parametrize(
    "url",
    [
        "https://ria.ru/a",
        "https://news.mail.ru/b",
        "https://gw2ru.com/c",
        "https://www.rt.com/d",
        "https://sputniknews.com/e",
    ],
)
def test_a_russian_source_holds_the_row(url: str) -> None:
    reason = machine_approval_block_reason(_q(source_url=url))
    assert reason and reason.startswith("uk_policy=russian_source(")


@pytest.mark.parametrize(
    "field", ["headline_answer", "topic", "source_excerpt", "explanation"]
)
def test_every_text_field_is_scanned(field: str) -> None:
    reason = machine_approval_block_reason(_q(**{field: "Москва"}))
    assert reason and "topic_policy" in reason


# --- 6. a changed gate set gets a new version --------------------------------


def test_gate_version_names_the_gate_set_that_knows_these_holes() -> None:
    # Rows approved under the leaky v1 uk gates stay findable by their stamp.
    assert GATE_VERSION == "machine:gates-v2"


# --- 8. folding keeps й and ї ---------------------------------------------------


def test_fold_keeps_ukrainian_letters_and_still_folds_latin_accents() -> None:
    assert fold("Київ") == "київ"
    assert fold("Йосип") != fold("Иосип")
    assert fold("Їжак") != fold("Іжак")
    assert fold("Šimon Pleško žirafa") == "simon plesko zirafa"
    # Different letters must not make two different Ukrainian words "cover"
    # each other through the stem matcher.
    assert not covers_tokens("Київська область", "Киівська обласна")


# --- 9. the Ukrainian apostrophe ʼ (U+02BC) -----------------------------------


def test_the_ukrainian_apostrophe_matches_the_ascii_one() -> None:
    assert _text_answers_match("мʼясо", ["м'ясо"])
    assert fold("мʼясо") == fold("м'ясо") == fold("м’ясо")
    assert normalize_text("Мʼясо") == normalize_text("М'ясо")


# --- 10. undated records and imperial units in Ukrainian -------------------------


@pytest.mark.parametrize(
    "text",
    ["Хто вперше піднявся на Говерлу?", "Який рекорд встановив Бубка?", "Яка печера найбільша у світі?"],
)
def test_uk_record_without_a_date_is_flagged(text: str) -> None:
    assert craft_guards.undated_record_reason(text, None, language="uk")
    assert machine_approval_block_reason(_q(question=text)).startswith("undated_flag=")
    # A year anchors it.
    assert not craft_guards.undated_record_reason(text + " (1880)", None, language="uk")


@pytest.mark.parametrize(
    "text", ["Висота 300 футів", "Відстань 26 миль", "Вага 10 фунтів", "Екран 6 дюймів", "Поле 100 ярдів"]
)
def test_uk_imperial_units_are_flagged(text: str) -> None:
    assert craft_guards.units_reason(text, "x", language="uk")
    assert craft_guards.units_reason(text + ", тобто 40 метрів", "x", language="uk") is None


def test_pounds_sterling_are_money_not_weight() -> None:
    assert craft_guards.units_reason("Ціна 5 фунтів стерлінгів", "x", language="uk") is None


def test_en_sk_cs_guards_do_not_see_the_uk_lists() -> None:
    for lang in (None, "en", "sk", "cs"):
        assert craft_guards.units_reason("Вага 10 фунтів", "x", language=lang) is None
        assert craft_guards.undated_record_reason("Хто вперше?", None, language=lang) is None
