"""#231 — numbers in Ukrainian questions and host lines are read grammatically.

Why these matter: the question is heard, not read, so a number in the wrong
case or gender ("два цілих", "сім з десять", "четвертого століття" for four
centuries) is the error a native speaker hears first, and a wrong ordinal can
change the fact the question asks about. Every expected string below was
checked by a Ukrainian editor's ear; the displayed text keeps its digits.
"""

from __future__ import annotations

import pytest
from app.daily_challenge import copy
from app.daily_challenge.rules import Crowd
from app.tts.number_normalization import normalize_numbers_for_tts

NBSP = " "


def say(text: str) -> str:
    return normalize_numbers_for_tts(text, "uk")


# ── Decimals: "ціла" is feminine, a dot is a decimal point too ───────────────


@pytest.mark.parametrize(
    ("text", "spoken"),
    [
        ("2,5 метра", "дві цілих п'ять десятих метра"),
        ("22,5", "двадцять дві цілих п'ять десятих"),
        ("1,5", "одна ціла п'ять десятих"),
        ("21,5", "двадцять одна ціла п'ять десятих"),
        ("2.5 метра", "дві цілих п'ять десятих метра"),
        # A non-whole percentage takes the genitive singular "відсотка".
        ("3.5%", "три цілих п'ять десятих відсотка"),
        ("2,5 %", "дві цілих п'ять десятих відсотка"),
        # A dot before exactly three digits still groups thousands.
        ("1.000 осіб", "тисяча осіб"),
    ],
)
def test_decimals_agree_with_the_feminine_whole(text, spoken):
    assert say(text) == spoken


# ── Ordinal suffixes: "1-го", "5-му", "1990-х" ───────────────────────────────


@pytest.mark.parametrize(
    ("text", "spoken"),
    [
        ("1-го травня", "першого травня"),
        ("у 5-му класі", "у п'ятому класі"),
        ("у 1990-х роках", "у тисяча дев'ятсот дев'яностих роках"),
        ("1990-ті роки", "тисяча дев'ятсот дев'яності роки"),
        ("2-га світова війна", "друга світова війна"),
        ("3-тя спроба", "третя спроба"),
        ("5-й клас", "п'ятий клас"),
        ("у 5-й школі", "у п'ятій школі"),
        ("на 2-й лінії", "на другій лінії"),
        ("на 3-му місці", "на третьому місці"),
        ("до 2-ї години", "до другої години"),
    ],
)
def test_suffix_gives_the_ordinal_its_case_and_gender(text, spoken):
    assert say(text) == spoken


# ── "століття" after 2–4 is a count unless the context needs a genitive ──────


@pytest.mark.parametrize(
    ("text", "spoken"),
    [
        ("Держава проіснувала 4 століття", "Держава проіснувала чотири століття"),
        ("Через 2 тисячоліття", "Через два тисячоліття"),
        ("з 4 століття", "з четвертого століття"),
        ("на початку 3 століття", "на початку третього століття"),
        ("4 століття до н. е.", "четвертого століття до н. е."),
        ("19 століття", "дев'ятнадцятого століття"),
        ("21 століття", "двадцять першого століття"),
    ],
)
def test_century_count_or_ordinal_by_context(text, spoken):
    assert say(text) == spoken


# ── Roman centuries ──────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("text", "spoken"),
    [
        ("XX століття", "двадцятого століття"),
        ("у XIX ст.", "у дев'ятнадцятому столітті."),
        ("у XIX ст. жили", "у дев'ятнадцятому столітті жили"),
        ("IV століття", "четвертого століття"),
        ("у ХХ столітті", "у двадцятому столітті"),  # typed with Cyrillic Х
        ("у XIX–XX століттях", "у дев'ятнадцятому – двадцятому століттях"),
        ("з XV по XVII століття", "з п'ятнадцятого по сімнадцяте століття"),
        ("на межі XIX–XX ст.", "на межі дев'ятнадцятого – двадцятого століть."),
        # A lone Cyrillic "І" is the word "and".
        ("І століття потому", "І століття потому"),
    ],
)
def test_roman_century_is_read_as_a_declined_ordinal(text, spoken):
    assert say(text) == spoken


# ── Years written with "р.", in spans, with plural nouns ─────────────────────


@pytest.mark.parametrize(
    ("text", "spoken"),
    [
        ("У 1969 р.", "У тисяча дев'ятсот шістдесят дев'ятому році."),
        (
            "у 1969 р. відбулася",
            "у тисяча дев'ятсот шістдесят дев'ятому році відбулася",
        ),
        (
            "між 1939 і 1945 роками",
            "між тисяча дев'ятсот тридцять дев'ятим і тисяча дев'ятсот сорок "
            "п'ятим роками",
        ),
        (
            "з 1939 по 1945 рік",
            "з тисяча дев'ятсот тридцять дев'ятого по тисяча дев'ятсот сорок "
            "п'ятий рік",
        ),
        (
            "у 1939–1945 рр.",
            "у тисяча дев'ятсот тридцять дев'ятому – тисяча дев'ятсот сорок "
            "п'ятому роках.",
        ),
        (
            "8 листопада 1945 р.",
            "восьмого листопада тисяча дев'ятсот сорок п'ятого року.",
        ),
        # An amount of years stays a cardinal.
        ("Місту 1500 років", "Місту тисяча п'ятсот років"),
    ],
)
def test_years_are_ordinals_beside_any_form_of_rik(text, spoken):
    assert say(text) == spoken


# ── "N з M": the second number in the genitive ───────────────────────────────

GENITIVES = {
    1: "одного", 2: "двох", 3: "трьох", 4: "чотирьох", 5: "п'яти", 6: "шести",
    7: "семи", 8: "восьми", 9: "дев'яти", 10: "десяти", 11: "одинадцяти",
    12: "дванадцяти", 13: "тринадцяти", 14: "чотирнадцяти", 15: "п'ятнадцяти",
    16: "шістнадцяти", 17: "сімнадцяти", 18: "вісімнадцяти", 19: "дев'ятнадцяти",
    20: "двадцяти", 21: "двадцяти одного", 25: "двадцяти п'яти", 30: "тридцяти",
    40: "сорока", 50: "п'ятдесяти", 60: "шістдесяти", 70: "сімдесяти",
    80: "вісімдесяти", 90: "дев'яноста", 100: "ста", 200: "двохсот",
    300: "трьохсот", 400: "чотирьохсот", 500: "п'ятисот", 600: "шестисот",
    700: "семисот", 800: "восьмисот", 900: "дев'ятисот", 1000: "тисячі",
}  # fmt: skip


@pytest.mark.parametrize(("m", "genitive"), sorted(GENITIVES.items()))
def test_out_of_takes_the_genitive(m, genitive):
    assert say(f"Знав 1 {copy.uk_from(m)} {m}.") == (
        f"Знав один {copy.uk_from(m)} {genitive}."
    )


@pytest.mark.parametrize(
    ("text", "spoken"),
    [
        # The daily challenge strip and the recap line the app sends.
        ("Це знали лише 2 із 9.", "Це знали лише два із дев'яти."),
        ("Правильних відповідей: 7 з 10.", "Правильних відповідей: сім з десяти."),
        ("3 з 2000", "три з двох тисяч"),
        ("1 з 21 000", "один з двадцяти однієї тисячі"),
    ],
)
def test_host_lines_read_the_total_in_the_genitive(text, spoken):
    assert say(text) == spoken


def test_sk_and_cs_counts_are_untouched():
    assert normalize_numbers_for_tts("7 z 10", "sk") == "sedem z desať"
    assert normalize_numbers_for_tts("2,5", "cs") == "dvě celé pět"


# ── Server review 2 (#231): forms a native speaker heard as wrong ────────────


@pytest.mark.parametrize(
    ("text", "spoken"),
    [
        (
            "Правильна відповідь: XIX століття.",
            "Правильна відповідь: дев'ятнадцяте століття.",
        ),
        ("Відповідь: 3 століття.", "Відповідь: третє століття."),
        ("Відповідь: XX ст.", "Відповідь: двадцяте століття."),
        ("Період: XIX століття", "Період: дев'ятнадцяте століття"),
        # Another label before 2–4 may still be a count.
        ("Тривалість: 3 століття", "Тривалість: три століття"),
    ],
)
def test_the_answer_names_its_century_in_the_nominative(text, spoken):
    """The feedback line "Правильна відповідь: {answer}" names the century, so
    it must not come out in the genitive ("дев'ятнадцятого") or as a count."""
    assert say(text) == spoken


@pytest.mark.parametrize(
    ("text", "spoken"),
    [
        ("З 1 по 5 травня", "З першого по п'яте травня"),
        ("з 1 до 5 травня", "з першого до п'ятого травня"),
        ("1–5 травня", "першого – п'ятого травня"),
        ("8 листопада", "восьмого листопада"),
    ],
)
def test_a_span_of_days_reads_both_days_as_dates(text, spoken):
    """«З один по п'ятого травня» mixes a count with a date; both ends of a
    span are days of the month, "по" taking the accusative."""
    assert say(text) == spoken


def test_a_dashed_decade_span_gives_both_years_the_suffix_case():
    """«шістдесят–…сімдесятих роках» left the first decade a bare cardinal."""
    assert say("У 1960–1970-х роках") == (
        "У тисяча дев'ятсот шістдесятих – тисяча дев'ятсот сімдесятих роках"
    )


@pytest.mark.parametrize(
    ("text", "spoken"),
    [
        ("Поїзд о 10.30", "Поїзд о десятій тридцять"),
        ("Поїзд о 10:30", "Поїзд о десятій тридцять"),
        ("о 7.05", "о сьомій нуль п'ять"),
        ("о 11.15", "об одинадцятій п'ятнадцять"),
        ("о 10.00", "о десятій"),
        # Sentence punctuation after the time keeps it a time.
        ("Поїзд о 10.30, потім", "Поїзд о десятій тридцять, потім"),
        ("Поїзд о 10:30, потім", "Поїзд о десятій тридцять, потім"),
        ("о 10.30.", "о десятій тридцять."),
        ("о 10.30?", "о десятій тридцять?"),
        ("(о 10.30)", "(о десятій тридцять)"),
        # Not a time: still a decimal.
        ("2.5 метра", "дві цілих п'ять десятих метра"),
    ],
)
def test_a_clock_time_after_o_is_not_a_decimal(text, spoken):
    """«о десять цілих три десятих» is a decimal where the question gives a
    time of day."""
    assert say(text) == spoken


def test_a_number_running_on_after_the_minutes_is_not_a_time():
    """«о 10.30,5» is no clock time; only a comma before a digit blocks it."""
    assert "десятій" not in say("о 10.30,5")


@pytest.mark.parametrize(
    ("text", "spoken"),
    [
        ("У 2100 році", "У дві тисячі сотому році"),
        ("у 2150 році", "у дві тисячі сто п'ятдесятому році"),
        ("у 2000 році", "у двохтисячному році"),
    ],
)
def test_years_after_2099_are_ordinals_too(text, spoken):
    """«У дві тисячі сто році» is a count where a year is meant."""
    assert say(text) == spoken


# ── Daily challenge: the verb agrees with "1 відсоток" ───────────────────────


def test_one_percent_knew_in_the_singular():
    crowd = Crowd(others=100, knew=1)
    assert copy.spoken_line("rare", crowd, "uk", 1) == "Лише 1 відсоток це знав."
    assert copy.spoken_line("rare", crowd, "uk", 0) == "Це знав лише 1 відсоток."
    assert copy.rare_text(crowd, "uk") == f"Це знав лише 1{NBSP}%."


def test_percent_verb_follows_the_plural_rule():
    assert copy.strip_text(Crowd(others=100, knew=21), "uk") == f"Знав 21{NBSP}%."
    assert copy.strip_text(Crowd(others=100, knew=22), "uk") == f"Знали 22{NBSP}%."
    assert copy.strip_text(Crowd(others=100, knew=11), "uk") == f"Знали 11{NBSP}%."
    assert say(copy.spoken_line("rare", Crowd(others=100, knew=1), "uk", 1)) == (
        "Лише один відсоток це знав."
    )
