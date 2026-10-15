"""#205 — the crowd rules the founder decided (2026-10-15), as pure functions.

Why these matter: a wrong answer most others knew must stay silent (negative
comparison is the one line with measured harm); small crowds show counts, never a
percentage built on three people; rank is shown only in the top half, never
"worse than…"; and the numbers are only ever real counts.
"""

import pytest

from app.daily_challenge import copy
from app.daily_challenge.rules import (
    MAX_SPOKEN_LINES,
    Crowd,
    Standing,
    classify,
    is_spoken,
    knew,
)


@pytest.mark.parametrize(
    "crowd,player_knew,kind",
    [
        (Crowd(others=0, knew=0), True, "first"),
        (Crowd(others=0, knew=0), False, "first"),
        (Crowd(others=10, knew=3), True, "rare"),  # 30 % is still rare
        (Crowd(others=10, knew=4), True, "plain"),
        (Crowd(others=10, knew=3), False, "hard"),
        (Crowd(others=10, knew=4), False, "hidden"),  # wrong + easy: no strip
        (Crowd(others=1, knew=1), False, "hidden"),
    ],
)
def test_rules_table(crowd, player_knew, kind):
    assert classify(crowd, player_knew) == kind


def test_only_rare_and_hard_are_spoken_and_at_most_three_times():
    assert is_spoken("rare", 0) and is_spoken("hard", MAX_SPOKEN_LINES - 1)
    assert not is_spoken("rare", MAX_SPOKEN_LINES)
    for quiet in ("first", "plain", "hidden"):
        assert not is_spoken(quiet, 0)
    assert MAX_SPOKEN_LINES == 3


def test_partially_correct_counts_as_knowing():
    assert knew("correct") and knew("partially_correct")
    assert not any(knew(r) for r in ("incorrect", "partially_incorrect", "skipped"))


@pytest.mark.parametrize(
    "language,crowd,text",
    [
        ("sk", Crowd(3, 2), "Vedeli 2 z 3."),
        ("sk", Crowd(3, 1), "Vedel 1 z 3."),
        ("sk", Crowd(19, 7), "Vedelo 7 z 19."),
        ("sk", Crowd(20, 3), "Vedelo 15 %."),
        ("cs", Crowd(3, 2), "Věděli 2 ze 3."),
        ("cs", Crowd(5, 0), "Nikdo jiný to nevěděl."),
        ("sk", Crowd(7, 3), "Vedeli 3 zo 7."),
        ("cs", Crowd(50, 7), "Vědělo 14 %."),
        ("en", Crowd(3, 2), "2 of 3 knew."),
        ("en", Crowd(100, 14), "14% knew."),
        ("sk", Crowd(0, 0), "Dnes si prvý."),
        ("cs", Crowd(0, 0), "Dnes jsi první."),
        ("en", Crowd(0, 0), "You're first today."),
    ],
)
def test_strip_counts_below_twenty_percent_from_twenty(language, crowd, text):
    assert copy.strip_text(crowd, language) == text


def test_unknown_language_falls_back_to_english():
    assert copy.strip_text(Crowd(3, 2), "de") == "2 of 3 knew."


@pytest.mark.parametrize(
    "n,prep",
    [
        (1, "z"),
        (2, "ze"),
        (3, "ze"),
        (5, "z"),
        (7, "ze"),
        (12, "ze"),
        (15, "z"),
        (20, "ze"),
        (25, "ze"),
        (50, "z"),
        (100, "ze"),
    ],
)
def test_czech_z_or_ze(n, prep):
    assert copy.cs_from(n) == prep


@pytest.mark.parametrize(
    "n,prep",
    [
        (3, "z"),
        (4, "zo"),
        (5, "z"),
        (7, "zo"),
        (14, "zo"),
        (20, "z"),
        (45, "zo"),
        (100, "zo"),
        (200, "z"),
    ],
)
def test_slovak_z_or_zo(n, prep):
    assert copy.sk_from(n) == prep


def test_spoken_lines_rotate_wording_and_stay_one_sentence():
    rare = Crowd(9, 2)
    first = copy.spoken_line("rare", rare, "sk", 0)
    second = copy.spoken_line("rare", rare, "sk", 1)
    assert first == "Vedeli to len 2 z 9."
    assert second == "Len 2 z 9 to vedeli."
    hard = {copy.spoken_line("hard", Crowd(9, 1), "sk", v) for v in range(3)}
    assert len(hard) == 3 and "Väčšina to nevie." in hard
    # Spoken percentages spell the word out for the TTS voice.
    assert (
        copy.spoken_line("rare", Crowd(50, 7), "sk", 0) == "Vedelo to len 14 percent."
    )
    assert (
        copy.spoken_line("rare", Crowd(0 + 4, 0), "en", 0) == "Nobody else knew that."
    )
    for line in hard | {first, second}:
        assert line.count(".") == 1 and " - " not in line and "–" not in line


def test_rank_only_in_top_half_never_worse_than():
    top = Standing(others=11, beaten=7, score=4, total=5)
    assert copy.comparison_text(top, "sk") == "Lepší ako 7 z 11 hráčov."
    assert copy.rank_text(top, "sk") == "Lepší ako 7 z 11 hráčov."

    bottom = Standing(others=11, beaten=2, score=2, total=5)
    assert copy.rank_text(bottom, "sk") is None
    assert copy.comparison_text(bottom, "sk") == "Ťažká výzva."
    for language in ("sk", "cs", "en"):
        line = copy.comparison_text(bottom, language) or ""
        assert "horš" not in line and "worse" not in line.lower()


def test_rank_uses_percent_from_twenty_players_and_best_of_when_beating_all():
    big = Standing(others=25, beaten=16, score=4, total=5)
    assert copy.rank_text(big, "sk") == "Lepší ako 64 % z 25 hráčov."
    assert copy.rank_text(big, "cs") == "Lepší než 64 % ze 25 hráčů."
    assert copy.rank_text(big, "en") == "Better than 64% of 25 players."
    best = Standing(others=1, beaten=1, score=4, total=5)
    assert copy.rank_text(best, "sk") == "Najlepšie skóre z 2 hráčov."


def test_first_player_and_perfect_tie():
    assert copy.comparison_text(Standing(0, 0, 3, 5), "sk") == "Dnes si prvý."
    # A perfect score tied with everyone is not a "tough challenge".
    assert copy.comparison_text(Standing(4, 0, 5, 5), "sk") is None
