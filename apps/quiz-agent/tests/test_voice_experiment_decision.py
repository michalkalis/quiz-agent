"""#204.9: the weekly verdict on the automatic voice-settings test (pure logic).

Why these tests matter: a "winner" is switched on for every player with no
human in the loop, and a "harm" verdict switches a setting off. So a wrong
filter or threshold silently changes how every answer in the car is
recorded. They pin: which answers count (only coin-decided ones, this
generation, this route, where the setting could act), what a bad capture is
(including a transcript the player later rejected), and the contract
thresholds (40 / 20 answers per arm, 95 %, 1 point expected loss, 6 weeks).
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from app.voice_experiment.decision import (
    ArmRow,
    ArmStats,
    Capture,
    aggregate,
    decide,
    posterior,
    rejected_flags,
)

START = datetime(2026, 10, 1, tzinfo=timezone.utc)
ROW = ArmRow("neural_vad", "bt_car", 1, START)


def _cap(on: bool, *, bad=False, i=0, flag="neural_vad", **extra) -> Capture:
    props = {
        "question_id": f"q{i}",
        f"src_{flag}": "auto",
        f"exp_gen_{flag}": 1,
        "route_group": "bt_car",
        flag: on,
        "stop_reason": "cap" if bad else "vad",
        "heard_speech": True,
        "rejected_count": 0,
    }
    props.update(extra)
    return Capture(f"s{i}", START + timedelta(minutes=i), props)


def _arms(on_n, on_bad, off_n, off_bad):
    caps = [_cap(True, bad=k < on_bad, i=k) for k in range(on_n)]
    caps += [_cap(False, bad=k < off_bad, i=1000 + k) for k in range(off_n)]
    return aggregate(caps, ROW)


def _decide(on_n, on_bad, off_n, off_bad, days=7):
    stats = _arms(on_n, on_bad, off_n, off_bad)
    post = posterior(stats[True], stats[False])
    return decide(ROW, stats[True], stats[False], post, START + timedelta(days=days))


def test_clear_winner_is_switched_on_for_everyone():
    d = _decide(50, 2, 50, 20)
    assert d is not None and (d.status, d.p_on, d.reason) == (
        "winner_on",
        1.0,
        "winner",
    )


def test_winner_needs_40_answers_per_arm_even_when_obvious():
    """Small samples lie; 39 vs 39 must keep running however lopsided."""
    assert _decide(39, 0, 39, 20) is None


def test_setting_that_hurts_is_switched_off_early():
    """Harm stops at 20 per arm so players do not suffer for 40 answers."""
    d = _decide(25, 15, 25, 2)
    assert d is not None and (d.status, d.p_on, d.reason) == ("off", 0.0, "harm")


def test_too_few_answers_decide_nothing():
    assert _decide(10, 9, 10, 0) is None


def test_no_difference_after_six_weeks_ends_off():
    assert _decide(60, 6, 60, 6, days=41) is None
    d = _decide(60, 6, 60, 6, days=42)
    assert d is not None and (d.status, d.p_on, d.reason) == (
        "off",
        0.0,
        "no_difference",
    )


def test_monte_carlo_is_reproducible():
    """Fixed seed: the same data must give the same verdict on a re-run."""
    on, off = ArmStats(n=40, bad=5), ArmStats(n=40, bad=9)
    assert posterior(on, off) == posterior(on, off)


def test_a_transcript_rejected_later_counts_as_bad():
    first = _cap(True, i=1, rejected_count=0)
    retry = Capture(
        "s1",
        first.occurred_at + timedelta(seconds=20),
        {**first.properties, "rejected_count": 1},
    )
    other_session = Capture(
        "s9",
        first.occurred_at + timedelta(seconds=30),
        {**first.properties, "rejected_count": 5},
    )
    flags = rejected_flags([first, retry, other_session])
    assert flags[id(first)] is True
    # The retry itself was accepted; another session never marks this one.
    assert flags[id(retry)] is False
    stats = aggregate([first, retry], ROW)
    assert (stats[True].n, stats[True].bad) == (2, 1)


def test_no_speech_is_bad():
    stats = aggregate([_cap(False, heard_speech=False)], ROW)
    assert stats[False].bad == 1


def test_only_coin_decided_answers_of_this_generation_and_route_count():
    """A manual switch, an old generation, another route or an answer from
    before the start would mix a different population into the arms."""
    caps = [
        _cap(True, i=1),
        _cap(True, i=2, src_neural_vad="manual"),
        _cap(True, i=3, exp_gen_neural_vad=2),
        _cap(True, i=4, route_group="other"),
        Capture("s5", START - timedelta(days=1), _cap(True, i=5).properties),
        _cap(True, i=6, neural_vad=None),
    ]
    assert aggregate(caps, ROW)[True].n == 1


def test_aec_and_front_mic_count_only_where_they_could_act():
    """AEC off the car route / front mic with voice processing on cannot
    change anything; counting those answers would dilute a real effect."""
    for flag in ("aec", "front_mic"):
        row = ArmRow(flag, "bt_car", 1, START)
        caps = [
            _cap(True, i=1, flag=flag, **{f"{flag}_applicable": True}),
            _cap(True, i=2, flag=flag, **{f"{flag}_applicable": False}),
            _cap(True, i=3, flag=flag),  # applicability unknown
        ]
        assert aggregate(caps, row)[True].n == 1, flag


def test_secondary_metrics_are_reported():
    caps = [_cap(True, i=1, end_delay_ms=300), _cap(True, i=2, end_delay_ms=900)]
    verdicts = {("s1", "q1"): "correct", ("s2", "q2"): "incorrect"}
    summary = aggregate(caps, ROW, verdicts)[True].summary()
    assert summary["median_end_delay_ms"] == 600
    assert summary["correct_share"] == 0.5


def test_only_the_attempt_right_before_a_rejection_counts_as_rejected():
    """rejected_count is cumulative: after one rejection every later capture
    carries 1. A retry that was not a rejection (e.g. no speech) followed by
    a rejected one must blame only the capture right before the count rose."""
    t = START
    caps = [
        Capture("s1", t + timedelta(seconds=s), {"question_id": "q1", "rejected_count": rc})
        for s, rc in ((0, 0), (10, 0), (20, 1), (30, 1))
    ]  # fmt: skip
    flags = rejected_flags(caps)
    assert [flags[id(c)] for c in caps] == [False, True, False, False]


def _stats(n_on, n_off):
    return ArmStats(n=n_on, bad=0), ArmStats(n=n_off, bad=0)


def test_winner_also_needs_a_small_expected_loss():
    """P(better) alone is not enough: if choosing ON could still cost ≥ 1
    point of bad captures, keep testing rather than switch everyone."""
    on, off = _stats(40, 40)
    post = {"p_on_better": 0.97, "p_on_worse": 0.03, "expected_loss_on": 0.01}
    assert decide(ROW, on, off, post, START + timedelta(days=7)) is None
    post["expected_loss_on"] = 0.0099
    assert decide(ROW, on, off, post, START + timedelta(days=7)).reason == "winner"


def test_harm_needs_20_answers_in_each_arm():
    post = {"p_on_better": 0.01, "p_on_worse": 0.99, "expected_loss_on": 0.3}
    now = START + timedelta(days=7)
    assert decide(ROW, *_stats(19, 20), post, now) is None
    assert decide(ROW, *_stats(20, 19), post, now) is None
    assert decide(ROW, *_stats(20, 20), post, now).reason == "harm"
