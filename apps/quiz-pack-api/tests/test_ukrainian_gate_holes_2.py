"""#231 — Ukrainian as a fourth language: holes a second independent review
found in the uk gates (2026-11-19).

Why these matter: a machine-approved row reaches App Store players with nobody
reading it. Founder rules for uk: no war since 2014, no current politics, no
relations with Russia; history, culture and sport are welcome; no Russian
letters, words, name forms or sources; the question must not give its answer
away. Holding a row (pending_review) is cheap, a wrong approval is expensive,
a wrong rejection silently loses a good question. The keyword lists leaked
twice, so for uk the naturalness model also flags policy and answer leaks.
Every input below is one the previous gates got wrong.
"""

from __future__ import annotations

import json
from typing import Any

import app.generation.naturalness_check as nc
import pytest
from app import uk_policy
from app.corpus.importer import _verification_block_reason
from app.generation.naturalness_check import NaturalnessChecker, apply_naturalness
from app.scoring import craft_guards
from app.scoring.machine_approval import (
    machine_approval_block_reason,
    tf_imbalance_excess_ids,
)
from quiz_shared.models.question import Question

CLEAN_VERDICT = {"ok": True, "off_policy": False, "gives_away": False}


def _q(**overrides: Any) -> Question:
    naturalness = overrides.pop("naturalness", CLEAN_VERDICT)
    base: dict[str, Any] = {
        "id": "q_uk",
        "question": "Яка планета обертається швидше за всіх?",
        "correct_answer": "Юпітер",
        "topic": "Наука",
        "category": "science",
        "difficulty": "medium",
        "language": "uk",
        "source_url": "https://uk.wikipedia.org/wiki/Юпітер",
        "generation_metadata": {
            "extra": {
                "verified": True,
                "verification_score": 0.9,
                "factcheck_tier": "web",
                "naturalness": naturalness,
            }
        },
    }
    base.update(overrides)
    return Question(**base)


# --- negative controls: good Ukrainian questions stay approvable -------------

GOOD = [
    ("Який червоний суп українці варять з буряком?", "Борщ"),
    ("Який клуб виграв Суперкубок УЄФА 1975 року?", "Динамо"),
    ("Хто написав драму-феєрію «Лісова пісня»?", "Леся Українка"),
    ("Хто створив обробку колядки «Щедрик»?", "Микола Леонтович"),
]


@pytest.mark.parametrize(("question", "answer"), GOOD)
def test_ordinary_good_questions_are_still_machine_approved(
    question: str, answer: str
) -> None:
    """The new lists must not swallow culture, food and sport."""
    assert machine_approval_block_reason(_q(question=question, correct_answer=answer)) is None


# --- 1. war and politics in other words are never machine-approved ----------

WAR_AND_POLITICS = [
    ("Яке місто на сході стало символом стійкості після тривалих боїв?", "Бахмут"),
    ("Який острів у Чорному морі прославився фразою прикордонників кораблю?", "Зміїний"),
    ("Хто є мером Києва?", "Віталій Кличко"),
    ("Який підрозділ Збройних сил України обороняв аеропорт?", "Десантники"),
    ("Кого в Україні прозвали «кіборгами»?", "Захисників аеропорту"),
    ("Що означала абревіатура АТО на сході країни?", "Антитерористична операція"),
    ("Як називається турецький безпілотник, що став символом опору?", "Байрактар"),
    ("Яке місто під Києвом звільнили навесні?", "Ірпінь"),
    ("Коли Україна подала заявку на вступ до НАТО?", "Восени"),
    ("Хто очолює уряд України?", "Шмигаль"),
    ("Як звати міністра оборони України?", "Не знаю"),
    ("Яка політична сила Юлії Тимошенко?", "Батьківщина"),
]


@pytest.mark.parametrize(("question", "answer"), WAR_AND_POLITICS)
def test_war_and_politics_in_other_words_are_held(question: str, answer: str) -> None:
    reason = machine_approval_block_reason(_q(question=question, correct_answer=answer))
    assert reason and reason.startswith("uk_policy=topic_policy")


# --- 2. Russian sources ------------------------------------------------------

RUSSIAN_SOURCES = [
    "https://ru.wikipedia.org/wiki/Киев",
    "https://ru.m.wikipedia.org/wiki/X",
    "https://tass.com/society/1",
    "https://www.rbth.com/history/1",
    "https://web.archive.org/web/2020/https://lenta.ru/news/1",
    "https://web.archive.org/web/2020/lenta.ru/news/1",
    "https://www.mrporter.com/en-ru/journal/x",
    "https://example.com/ru-ru/page",
]


@pytest.mark.parametrize("url", RUSSIAN_SOURCES)
def test_a_russian_source_in_any_disguise_holds_the_row(url: str) -> None:
    reason = machine_approval_block_reason(_q(source_url=url))
    assert reason and reason.startswith("uk_policy=russian_source(")


@pytest.mark.parametrize(
    "url",
    [
        "https://uk.wikipedia.org/wiki/Київ",
        "https://www.ukrinform.ua/rubric-culture/1.html",
        "https://web.archive.org/web/2020/https://uk.wikipedia.org/wiki/Київ",
        "https://www.britannica.com/place/Kyiv",
    ],
)
def test_ordinary_sources_are_not_flagged(url: str) -> None:
    assert uk_policy.source_reason(url) is None


# --- 3. Russian name forms and short Russian text ----------------------------

RUSSIAN_NAMES = [
    "Владимир", "Николай", "Сергей", "Андрей", "Чернигов", "Донецк",
    "Ровно", "Николаев", "Днестр", "Кривой Рог",
]


@pytest.mark.parametrize("name", RUSSIAN_NAMES)
def test_a_russian_name_form_as_the_answer_is_held(name: str) -> None:
    # The answer is what the player hears read out and the grader accepts.
    reason = machine_approval_block_reason(_q(correct_answer=name))
    assert reason and reason.startswith("uk_policy=russian")


def test_a_short_all_russian_question_is_held() -> None:
    reason = machine_approval_block_reason(
        _q(question="Кто написал роман «Мастер и Маргарита»?", correct_answer="Булгаков")
    )
    assert reason and reason.startswith("uk_policy=russian")


@pytest.mark.parametrize(
    "text",
    [
        "Володимир", "Микола", "Сергій", "Андрій", "Чернігів", "Донецьк",
        "Рівне", "Миколаїв", "Дністер", "Кривий Ріг", "Кривого Рогу",
        "Хто написав «Кобзар»?", "Зі сталі", "Нікола Тесла",
    ],
)
def test_the_ukrainian_forms_are_not_mistaken_for_russian(text: str) -> None:
    assert uk_policy.russian_contamination_reason([text]) is None


# --- 4. innocent history next to a recent year is held, never rejected -------

INNOCENT = [
    ["Яке місто зруйнувала монгольська облога 1240 року?", "Розкопки 2015 року підтвердили це."],
    ["Хто написав «Кобзар»?", "У 2014 році відзначали 200-річчя з дня народження Шевченка, а він був у засланні після війни."],
    ["Який фільм про Другу світову війну вийшов у 2019 році?"],
    ["Хто став президентом УЄФА у 2016 році?"],
    ["Коли розпочалася повномасштабна реставрація Софійського собору?"],
]


@pytest.mark.parametrize("texts", INNOCENT)
def test_innocent_history_is_held_for_a_human_not_rejected(texts: list[str]) -> None:
    """A reject never reaches a human: the good question would be lost."""
    assert uk_policy.topic_reject_reason(texts) is None
    assert (uk_policy.topic_policy_reason(texts) or "").startswith(uk_policy.HOLD_PREFIX)
    row = _q(question=texts[0], explanation=texts[1] if len(texts) > 1 else None)
    assert _verification_block_reason(row) is None  # the importer keeps it


@pytest.mark.parametrize(
    "text",
    [
        "Коли почалося повномасштабне вторгнення?",
        "Яке місто 2023 року стало відоме боями за Бахмут?",
        "Окупація Криму 2014 року.",
    ],
)
def test_the_war_with_its_year_or_name_is_still_rejected(text: str) -> None:
    assert uk_policy.topic_reject_reason([text]) is not None


def test_bare_full_scale_still_holds() -> None:
    # "з початку повномасштабного" means the invasion without the noun.
    reason = uk_policy.topic_policy_reason(["Що змінилося з початку повномасштабного?"])
    assert reason and reason.startswith(uk_policy.HOLD_PREFIX)


# --- 5. Ukrainian true/false answers are balanced too ------------------------


def test_ukrainian_true_false_answers_are_recognised() -> None:
    assert craft_guards.true_false_key("Правда") == "true"
    assert craft_guards.true_false_key("Неправда") == "false"
    assert craft_guards.true_false_key("B", {"A": "Правда", "B": "Неправда"}) == "false"


def test_an_all_true_ukrainian_batch_is_not_all_approved() -> None:
    # A player who always says "Правда" must not win every T/F question.
    rows = [
        _q(id=f"tf{i}", question=f"Говерла — найвища гора України? ({i})", correct_answer="Правда")
        for i in range(6)
    ]
    excess = tf_imbalance_excess_ids(rows)
    assert excess
    assert all(
        machine_approval_block_reason(r, excess) == "craft_flag=tf_key_imbalance"
        for r in rows
        if r.id in excess
    )


# --- the model verdict: off_policy and gives_away (holes 1 and 6) -----------


def _checker(item: dict, monkeypatch: pytest.MonkeyPatch) -> NaturalnessChecker:
    monkeypatch.setattr(nc.llm_factory, "chat_available", lambda m: True)
    checker = NaturalnessChecker(model="claude-opus-5-5")
    checker.prompts = []  # type: ignore[attr-defined]

    async def fake(prompt: str) -> str:
        checker.prompts.append(prompt)  # type: ignore[attr-defined]
        return json.dumps({"checks": [dict({"index": 1}, **item)]})

    checker._complete = fake  # type: ignore[assignment]
    return checker


KYIV_LEAK = {
    "question": "Яке місто святкує День Києва в останню неділю травня?",
    "correct_answer": "Київ",
}


@pytest.mark.asyncio
async def test_an_answer_given_away_in_another_case_is_held(monkeypatch) -> None:
    """«День Києва» gives away «Київ»: no keyword list can see the case."""
    row = _q(**KYIV_LEAK, naturalness=None)
    item = {"ok": True, "problems": [], "rewrite": None, "off_policy": False, "gives_away": True}
    checker = _checker(item, monkeypatch)
    assert await checker.label([row]) == 1
    prompt = checker.prompts[0]  # type: ignore[attr-defined]
    assert "answer: Київ" in prompt and '"gives_away"' in prompt
    assert machine_approval_block_reason(row) == "naturalness=gives_away"


@pytest.mark.asyncio
async def test_war_the_lists_miss_is_held_by_the_model(monkeypatch) -> None:
    """A wording no list knows yet: the model's off_policy flag holds it."""
    row = _q(question="Яке місто на сході стало символом стійкості?", correct_answer="Вугледар")
    item = {"ok": True, "problems": [], "rewrite": None, "off_policy": True, "gives_away": False}
    (verdict,) = await _checker(item, monkeypatch).check([row])
    apply_naturalness(row, verdict)
    assert machine_approval_block_reason(row) == "naturalness=off_policy"


@pytest.mark.parametrize(
    "flags",
    [{}, {"off_policy": False}, {"off_policy": "no", "gives_away": False}],
)
@pytest.mark.asyncio
async def test_missing_or_unparseable_flags_leave_a_uk_row_unchecked(
    flags: dict, monkeypatch
) -> None:
    # Fail closed: unchecked = naturalness=missing = pending; the backfill retries.
    item = {"ok": True, "problems": [], "rewrite": None, **flags}
    assert await _checker(item, monkeypatch).check([_q()]) == [None]


def test_an_old_verdict_without_flags_is_not_approved() -> None:
    assert machine_approval_block_reason(_q(naturalness={"ok": True})) == (
        "naturalness=off_policy"
    )


@pytest.mark.asyncio
async def test_sk_is_unchanged_by_the_uk_flags(monkeypatch) -> None:
    sk = _q(language="sk", question="Ktorá planéta sa točí najrýchlejšie?")
    checker = _checker({"ok": True, "problems": [], "rewrite": None}, monkeypatch)
    (verdict,) = await checker.check([sk])
    apply_naturalness(sk, verdict)
    prompt = checker.prompts[0]  # type: ignore[attr-defined]
    assert "off_policy" not in prompt and "answer:" not in prompt
    assert set(sk.generation_metadata.extra["naturalness"]) == {
        "ok", "problems", "rewrite", "model", "version"
    }
