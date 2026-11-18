"""#231.1 — the server knows Ukrainian (``uk``) but does not serve it yet.

Why these matter: ``uk`` is the fourth language. Every per-language branch the
server has for sk/cs must also exist for uk, or a Ukrainian session would hear
English fallbacks, digits in the wrong language, or a "чотири" that never picks
option 4. And the rollout is env-gated: nothing here may make ``uk`` servable
or orderable by default, and nothing may change what en/sk/cs produce.
"""

from __future__ import annotations

import pytest
from app.api.deps import get_question_retriever
from app.api.routes import app_config as app_config_routes
from app.api.routes import public_questions
from app.daily_challenge import copy
from app.daily_challenge.rules import Crowd, Standing
from app.evaluation.mcq_matcher import (
    label_keyterms,
    match_option,
    spoken_label,
)
from app.evaluation.spelling import collapse_spelling
from app.evaluation.voice_match import fold
from app.rate_limit import limiter
from app.translation.feedback_messages import (
    get_correct_answer_message,
    get_feedback_message,
)
from app.tts.number_normalization import normalize_numbers_for_tts
from app.tts.ordinals import ordinal_words
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from quiz_shared.languages import (
    QUIZ_LANGUAGES,
    pack_order_languages,
    servable_quiz_languages,
)

CITIES = {"a": "Париж", "b": "Лондон", "c": "Берлін", "d": "Мадрид"}
YEARS = {"a": "1969", "b": "1970", "c": "1971", "d": "1972"}
NBSP = " "


# ── Rollout gate ────────────────────────────────────────────────────────────


def test_uk_is_known_but_not_served_by_default(monkeypatch):
    """Data model knows uk; the menu stays en,sk,cs until the founder flips env."""
    monkeypatch.delenv("SERVABLE_QUIZ_LANGUAGES", raising=False)
    monkeypatch.delenv("PACK_ORDER_LANGUAGES", raising=False)
    assert "uk" in QUIZ_LANGUAGES
    assert servable_quiz_languages() == ("en", "sk", "cs")
    assert pack_order_languages() == ("en", "sk", "cs")


def test_uk_can_be_enabled_by_env_alone(monkeypatch):
    monkeypatch.setenv("SERVABLE_QUIZ_LANGUAGES", "en,sk,cs,uk")
    assert servable_quiz_languages() == ("en", "sk", "cs", "uk")


# ── Public questions route ──────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_public_fresh_questions_accepts_uk_once_listed(monkeypatch):
    # #231: the feed serves uk only after SERVABLE_QUIZ_LANGUAGES lists it
    # (dark by default, see test_public_fresh_questions_route).
    monkeypatch.setenv("SERVABLE_QUIZ_LANGUAGES", "en,sk,cs,uk")

    class Retriever:
        calls: list = []

        async def fresh_public_entertainment(self, language, limit):
            self.calls.append(language)
            return []

    retriever = Retriever()
    limiter.reset()
    app = FastAPI()
    app.state.limiter = limiter
    app.include_router(public_questions.router, prefix="/api/v1")
    app.dependency_overrides[get_question_retriever] = lambda: retriever
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as c:
        resp = await c.get("/api/v1/public/fresh-questions?language=uk")
    assert resp.status_code == 200
    assert resp.json()["language"] == "uk"
    assert retriever.calls == ["uk"]


# ── /app-config notice ──────────────────────────────────────────────────────


async def _notice(monkeypatch, **env):
    for name in ("APP_NOTICE_SK", "APP_NOTICE_CS", "APP_NOTICE_EN", "APP_NOTICE_UK"):
        monkeypatch.delenv(name, raising=False)
    for name, value in env.items():
        monkeypatch.setenv(name, value)
    app = FastAPI()
    app.include_router(app_config_routes.router, prefix="/api/v1")
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        return (await client.get("/api/v1/app-config")).json()["notice"]


@pytest.mark.asyncio
async def test_notice_carries_uk_when_set(monkeypatch):
    notice = await _notice(
        monkeypatch, APP_NOTICE_EN="Short break.", APP_NOTICE_UK="Коротка перерва."
    )
    assert notice["uk"] == "Коротка перерва."
    assert notice["en"] == "Short break."


@pytest.mark.asyncio
async def test_notice_without_uk_omits_the_field_so_the_client_falls_back_to_en(
    monkeypatch,
):
    """Old and new clients read the same three-language body when uk is blank."""
    notice = await _notice(monkeypatch, APP_NOTICE_EN="Short break.")
    assert "uk" not in notice
    assert notice["en"] == "Short break."


@pytest.mark.asyncio
async def test_uk_only_notice_is_still_a_notice(monkeypatch):
    assert (await _notice(monkeypatch, APP_NOTICE_UK="Тільки українською."))["uk"]


# ── TTS numbers ─────────────────────────────────────────────────────────────


def test_percent_and_digits_are_spelled_in_ukrainian():
    assert normalize_numbers_for_tts("Знали 70 %", "uk") == "Знали сімдесят відсотків"


@pytest.mark.parametrize(
    ("digits", "word"),
    [
        (1, "відсоток"),
        (2, "відсотки"),
        (5, "відсотків"),
        (11, "відсотків"),
        (21, "відсоток"),
        (22, "відсотки"),
        (25, "відсотків"),
    ],
)
def test_percent_word_follows_the_ukrainian_plural_rule(digits, word):
    assert normalize_numbers_for_tts(f"{digits}%", "uk").endswith(word)


@pytest.mark.parametrize(
    ("text", "spoken"),
    [
        # A year before "рік/року/році" is an ordinal adjective in uk (unlike sk/cs
        # "v roku 1969"): a cardinal here is the grammar error a native hears first.
        ("У 1969 році", "У тисяча дев'ятсот шістдесят дев'ятому році"),
        ("до 1991 року", "до тисяча дев'ятсот дев'яносто першого року"),
        ("У 2004 році", "У дві тисячі четвертому році"),
        # Round years fuse into one word.
        ("у 2000 році", "у двохтисячному році"),
        ("У 1900 році", "У тисяча дев'ятисотому році"),
        # A count is not a year: stays cardinal.
        ("Населення 1969 осіб", "Населення тисяча дев'ятсот шістдесят дев'ять осіб"),
    ],
)
def test_year_is_read_as_a_declined_ordinal(text, spoken):
    assert normalize_numbers_for_tts(text, "uk") == spoken


def test_decimal_comma_is_a_decimal_point_not_thousands():
    """sk/cs founder bug 2026-11-16 must not come back in uk: 30,126 is not 30126."""
    assert (
        normalize_numbers_for_tts("Курс 30,126", "uk")
        == "Курс тридцять цілих сто двадцять шість тисячних"
    )
    assert normalize_numbers_for_tts("1,5", "uk") == "одна ціла п'ять десятих"
    assert normalize_numbers_for_tts("3,05", "uk") == "три цілих п'ять сотих"


def test_at_sign_and_ampersand_are_words():
    assert normalize_numbers_for_tts("знак @ у пошті", "uk") == "знак равлик у пошті"
    assert normalize_numbers_for_tts("Том & Джеррі 2", "uk") == "Том і Джеррі два"


def test_sk_percent_unchanged():
    assert normalize_numbers_for_tts("5 %", "sk") == "päť percent"


# ── Ordinals and dates ──────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("text", "spoken"),
    [
        ("8 листопада", "восьмого листопада"),
        ("1 січня", "першого січня"),
        ("21 травня", "двадцять першого травня"),
        ("3 березня", "третього березня"),
        ("19 століття", "дев'ятнадцятого століття"),
        ("у 20 столітті", "у двадцятому столітті"),
        ("1. 1. 2026", "першого січня дві тисячі двадцять шостого"),
        ("2. світова війна", "друга світова війна"),
        ("під час 2. світової війни", "під час другої світової війни"),
        ("3. місце", "третє місце"),
    ],
)
def test_uk_ordinals_and_dates(text, spoken):
    from app.tts.ordinals import spell_ordinals

    assert spell_ordinals(text, "uk") == spoken


def test_uk_ordinals_run_before_the_cardinal_pass():
    assert (
        normalize_numbers_for_tts("8 листопада 1945", "uk")
        == "восьмого листопада тисяча дев'ятсот сорок п'ятого"
    )


def test_a_plain_count_before_a_noun_stays_a_cardinal():
    assert normalize_numbers_for_tts("5 гравців", "uk") == "п'ять гравців"


def test_ordinal_words_tens_stay_cardinal():
    assert ordinal_words(40, "uk", "m_nom") == "сороковий"
    assert ordinal_words(99, "uk", "gen") == "дев'яносто дев'ятого"


# ── MCQ matcher ─────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("said", "key"),
    [
        ("один", "a"),
        ("два", "b"),
        ("три", "c"),
        ("чотири", "d"),
        ("Чотири", "d"),
        ("це чотири", "d"),
        ("варіант три", "c"),
        ("перший", "a"),
        ("перша", "a"),
        ("перше", "a"),
        ("другий", "b"),
        ("друга", "b"),
        ("друге", "b"),
        ("другу", "b"),
        ("третій", "c"),
        ("третя", "c"),
        ("третє", "c"),
        ("третього", "c"),
        ("четвертий", "d"),
        ("четверта", "d"),
        ("четверте", "d"),
        ("останній", "d"),
        ("двійка", "b"),
        ("трійку", "c"),
        ("четвірка", "d"),
        ("4", "d"),
        ("2", "b"),
    ],
)
def test_ukrainian_numbers_ordinals_and_digits_pick_the_option(said, key):
    assert match_option(said, CITIES) == key


def test_option_text_still_wins_in_cyrillic():
    assert match_option("це Берлін", CITIES) == "c"


def test_negation_in_ukrainian_never_matches():
    assert match_option("не третій", CITIES) is None


def test_letters_scheme_names_in_cyrillic():
    """Numeric options are labelled A-D; А Б В Г said alone pick them."""
    assert match_option("бе", YEARS) == "b"
    assert match_option("ге", YEARS) == "d"
    assert match_option("Б", YEARS) == "b"
    assert match_option("в", YEARS) == "c"


def test_spoken_label_and_keyterms_in_ukrainian():
    assert [spoken_label(str(i), "uk") for i in (1, 2, 3, 4)] == [
        "Один",
        "Два",
        "Три",
        "Чотири",
    ]
    assert label_keyterms({"a": "1", "b": "4"}, "uk") == ["один", "чотири"]


def test_fold_keeps_y_and_yi_apart_from_i():
    """й/и and ї/і are different letters: "лій"/"ли" must not collapse into one word."""
    assert fold("Київ") != fold("Кіив")
    assert fold("мій") != fold("ми")
    assert fold("Їжак!") == "їжак"
    # Latin folding is untouched.
    assert fold("Štyri") == "styri"


# ── Spelling ────────────────────────────────────────────────────────────────


def test_spelled_ukrainian_name_is_joined():
    assert collapse_spelling("бе и че") == "бич"
    # "де" ("where") and "те" ("that") are ordinary words: never a spelling alone.
    assert collapse_spelling("де те ка") == "де те ка"


# ── Feedback ────────────────────────────────────────────────────────────────


def test_feedback_lines_in_ukrainian_not_english_fallback():
    assert get_feedback_message("correct", "uk") == "Правильно!"
    assert get_feedback_message("skipped", "uk") == "Пропущено."
    assert (
        get_correct_answer_message("incorrect", "Париж", "uk")
        == "Неправильно. Правильна відповідь: Париж."
    )


def test_every_uk_template_covers_every_result_like_sk():
    from app.translation.feedback_messages import (
        CORRECT_ANSWER_TEMPLATES,
        FEEDBACK_MESSAGES,
    )

    assert (
        CORRECT_ANSWER_TEMPLATES["uk"].keys() == CORRECT_ANSWER_TEMPLATES["sk"].keys()
    )
    assert FEEDBACK_MESSAGES["uk"].keys() == FEEDBACK_MESSAGES["sk"].keys()


# ── Daily challenge copy ────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("n", "form"),
    [
        (1, "відсоток"),
        (2, "відсотки"),
        (5, "відсотків"),
        (11, "відсотків"),
        (12, "відсотків"),
        (14, "відсотків"),
        (21, "відсоток"),
        (22, "відсотки"),
        (25, "відсотків"),
        (0, "відсотків"),
        (30, "відсотків"),
    ],
)
def test_uk_plural_one_few_many(n, form):
    assert copy.uk_plural(n, "відсоток", "відсотки", "відсотків") == form


def test_uk_count_strip_and_rank_lines():
    assert copy.strip_text(Crowd(others=9, knew=5), "uk") == "Знали 5 із 9."
    assert copy.strip_text(Crowd(others=9, knew=1), "uk") == "Знав 1 із 9."
    assert copy.strip_text(Crowd(others=0, knew=0), "uk") == "Перший результат дня."
    assert copy.strip_text(Crowd(others=100, knew=70), "uk") == f"Знали 70{NBSP}%."


def test_uk_from_uses_zi_only_before_a_hundred_something():
    assert copy.uk_from(9) == "із"
    assert copy.uk_from(100) == "зі"
    assert copy.uk_from(250) == "із"


def test_players_noun_agrees_with_the_number_after_iz():
    """ "із 21 гравця" (singular genitive), "із 22 гравців"."""

    def s(n):
        standing = Standing(others=n - 1, beaten=n - 1, score=3, total=3)
        return copy.rank_text(standing, "uk")

    assert s(21) == "Найкращий результат із 21 гравця."
    assert s(22) == "Найкращий результат із 22 гравців."
    assert s(5) == "Найкращий результат із 5 гравців."


def test_uk_rare_and_hard_lines_are_spoken():
    line = copy.spoken_line("rare", Crowd(others=100, knew=3), "uk", 0)
    assert line == "Це знали лише 3 відсотки."
    assert (
        copy.spoken_line("rare", Crowd(others=100, knew=1), "uk", 1)
        == "Лише 1 відсоток це знали."
    )
    assert (
        copy.spoken_line("hard", Crowd(others=10, knew=0), "uk", 0)
        == "Більшість цього не знає."
    )


def test_other_languages_unchanged_and_unknown_falls_back_to_english():
    assert copy.strip_text(Crowd(others=9, knew=5), "sk") == "Vedelo 5 z 9."
    assert copy.strip_text(Crowd(others=9, knew=5), "de") == "5 of 9 knew."
