"""Unit tests for the issue #72 Phase-5 validation harness.

The harness asserts machine-checkable QUALITY PROXIES over generated questions
and must NEVER write to the corpus. These tests exercise every proxy on
synthetic data (pass + fail) and prove the corpus-write guard and dry-run
stage shape — the Phase-5 gate: "harness unit-tested on synthetic data;
dry-run shape OK". No LLM, no network, no DB.
"""

from __future__ import annotations

import pytest

from quiz_shared.models.question import Question

import scripts.validate_generation as vg


def _q(**overrides) -> Question:
    """Synthetic generated question; override any field per test."""
    data = {
        "id": "q-72-p5-fixture",
        "question": "How many times does a hummingbird's heart beat per minute?",
        "type": "text",
        "correct_answer": "about 1200",
        "topic": "the human body",
        "category": "science",
        "difficulty": "medium",
        "generation_metadata": {"reasoning_pattern": "estimation"},
    }
    data.update(overrides)
    return Question.from_dict(data)


def _mcq(pattern: str, *, correct: str = "c", **overrides) -> Question:
    data = {
        "id": "q-72-p5-mcq",
        "question": "Of these four, which formed most recently?",
        "type": "text_multichoice",
        "possible_answers": {"a": "Earth", "b": "Jupiter", "c": "the Moon", "d": "the Sun"},
        "correct_answer": correct,
        "topic": "space exploration",
        "category": "science",
        "difficulty": "medium",
        "generation_metadata": {"reasoning_pattern": pattern},
    }
    data.update(overrides)
    return Question.from_dict(data)


def _clean_batch() -> list[Question]:
    """A batch engineered to pass every proxy — the keystone green case."""
    return [
        _q(generation_metadata={"reasoning_pattern": "estimation"}),
        _q(
            question="A puzzle: what links a piano and a typewriter?",
            correct_answer="keys",
            generation_metadata={"reasoning_pattern": "lateral_thinking_puzzle"},
        ),
        _mcq("odd_one_out", correct="c"),
        _mcq(
            "order_of_magnitude",
            correct="b",
            question="Roughly how many cells are in the human body?",
            possible_answers={"a": "thousands", "b": "trillions", "c": "hundreds", "d": "dozens"},
        ),
        _mcq(
            "comparison_bet_older_larger",
            correct="a",
            question="Older: the Colosseum or the Great Wall?",
            possible_answers={"a": "Great Wall", "b": "Colosseum"},
        ),
    ]


# --------------------------------------------------------------------------- #
# proxy_non_empty
# --------------------------------------------------------------------------- #


def test_non_empty_fails_on_empty_batch():
    assert vg.proxy_non_empty([]).passed is False


def test_non_empty_passes_with_questions():
    assert vg.proxy_non_empty([_q()]).passed is True


# --------------------------------------------------------------------------- #
# proxy_non_recall_per_type
# --------------------------------------------------------------------------- #


def test_non_recall_per_type_passes_when_each_type_has_reasoning():
    batch = [_q(), _mcq("odd_one_out")]
    assert vg.proxy_non_recall_per_type(batch).passed is True


def test_non_recall_per_type_fails_when_a_type_is_all_recall():
    # text type has a reasoning pattern, but the MCQ type is pure recall.
    batch = [_q(), _mcq("true_false")]
    result = vg.proxy_non_recall_per_type(batch)
    assert result.passed is False
    assert any("text_multichoice" in v for v in result.violations)


# --------------------------------------------------------------------------- #
# proxy_pattern_diversity
# --------------------------------------------------------------------------- #


def test_pattern_diversity_passes_at_threshold():
    batch = [_q(generation_metadata={"reasoning_pattern": p}) for p in (
        "estimation",
        "odd_one_out",
        "reverse_engineer",
    )]
    assert vg.proxy_pattern_diversity(batch).passed is True


def test_pattern_diversity_fails_below_threshold():
    batch = [_q(generation_metadata={"reasoning_pattern": p}) for p in ("estimation", "odd_one_out")]
    assert vg.proxy_pattern_diversity(batch).passed is False


def test_pattern_diversity_ignores_recall_patterns():
    # Three patterns, but two are recall — only one distinct reasoning pattern.
    batch = [
        _q(generation_metadata={"reasoning_pattern": "estimation"}),
        _q(generation_metadata={"reasoning_pattern": "true_false"}),
        _q(generation_metadata={"reasoning_pattern": "historical_quirk"}),
    ]
    assert vg.proxy_pattern_diversity(batch).passed is False


# --------------------------------------------------------------------------- #
# proxy_no_banned_openers
# --------------------------------------------------------------------------- #


@pytest.mark.parametrize(
    "text",
    [
        "What is the capital of France?",
        "WHO WROTE Hamlet?",
        "What year did the war end?",
        "Which author penned 1984?",
    ],
)
def test_banned_openers_caught(text):
    result = vg.proxy_no_banned_openers([_q(question=text)])
    assert result.passed is False
    assert result.violations


def test_banned_openers_passes_clean_text():
    assert vg.proxy_no_banned_openers([_q()]).passed is True


# --------------------------------------------------------------------------- #
# proxy_which_opener_fraction
# --------------------------------------------------------------------------- #


def test_which_fraction_fails_when_majority_which():
    batch = [_q(question="Which planet is largest?"), _q(question="Which ocean is deepest?")]
    assert vg.proxy_which_opener_fraction(batch).passed is False


def test_which_fraction_passes_under_cap():
    batch = [_q(question="Which planet is largest?")] + [_q() for _ in range(4)]
    # 1/5 = 20% <= 30%
    assert vg.proxy_which_opener_fraction(batch).passed is True


# --------------------------------------------------------------------------- #
# proxy_mcq_valid
# --------------------------------------------------------------------------- #


def test_mcq_valid_passes_good_options():
    assert vg.proxy_mcq_valid([_mcq("odd_one_out")]).passed is True


def test_mcq_valid_fails_when_correct_key_absent():
    assert vg.proxy_mcq_valid([_mcq("odd_one_out", correct="z")]).passed is False


def test_mcq_valid_fails_with_single_option():
    bad = _mcq("odd_one_out", correct="a", possible_answers={"a": "Only one"})
    assert vg.proxy_mcq_valid([bad]).passed is False


def test_mcq_valid_fails_on_duplicate_option_values():
    dup = _mcq("odd_one_out", correct="a", possible_answers={"a": "Mars", "b": "Mars"})
    assert vg.proxy_mcq_valid([dup]).passed is False


def test_mcq_valid_ignores_open_questions():
    assert vg.proxy_mcq_valid([_q()]).passed is True


# --------------------------------------------------------------------------- #
# proxy_answer_brevity
# --------------------------------------------------------------------------- #


def test_answer_brevity_passes_short_open_answer():
    assert vg.proxy_answer_brevity([_q(correct_answer="about 1200")]).passed is True


def test_answer_brevity_fails_long_open_answer():
    wordy = _q(correct_answer="one two three four five six seven eight")
    assert vg.proxy_answer_brevity([wordy]).passed is False


def test_answer_brevity_resolves_mcq_key_to_value():
    # correct_answer "c" must resolve to the option value "the Moon" (2 words), not the key.
    assert vg.proxy_answer_brevity([_mcq("odd_one_out", correct="c")]).passed is True


# --------------------------------------------------------------------------- #
# aggregator + keystone green batch
# --------------------------------------------------------------------------- #


def test_run_proxies_returns_one_result_per_proxy():
    results = vg.run_proxies(_clean_batch())
    assert len(results) == len(vg.ALL_PROXIES)


def test_clean_batch_passes_every_proxy():
    results = vg.run_proxies(_clean_batch())
    failures = [r.name for r in results if not r.passed]
    assert vg.all_passed(results), f"clean batch unexpectedly failed: {failures}"


def test_report_lines_mark_pass_and_fail():
    results = vg.run_proxies([_q(question="What is the capital of Peru?")])
    text = "\n".join(vg.report_lines(results))
    assert "[PASS]" in text and "[FAIL]" in text


# --------------------------------------------------------------------------- #
# corpus-write guard (issue #72 stop condition)
# --------------------------------------------------------------------------- #


class _FakeStage:
    def __init__(self, name: str) -> None:
        self.name = name


def test_guard_passes_on_persist_free_stages():
    stages = [_FakeStage("sourcing"), _FakeStage("generation"), _FakeStage("scoring")]
    vg.assert_no_corpus_write(stages)  # must not raise


def test_guard_raises_on_persisting_stage_name():
    stages = [_FakeStage("sourcing"), _FakeStage(vg.PERSIST_STAGE_NAME)]
    with pytest.raises(RuntimeError, match="never write to the corpus"):
        vg.assert_no_corpus_write(stages)


def test_guard_raises_on_persist_stage_class():
    class PersistStage:  # name-based escape: matched by class name
        name = "something-else"

    with pytest.raises(RuntimeError):
        vg.assert_no_corpus_write([_FakeStage("sourcing"), PersistStage()])


# --------------------------------------------------------------------------- #
# dry-run shape OK
# --------------------------------------------------------------------------- #


def test_build_dry_run_stages_shape_is_persist_free():
    stages = vg.build_dry_run_stages()
    assert stages, "dry-run stage list is empty"
    assert stages[0].name == "sourcing", "PackGenerator requires sourcing first"
    assert all(not vg._is_persister(s) for s in stages)
    vg.assert_no_corpus_write(stages)  # redundant belt-and-suspenders


# --------------------------------------------------------------------------- #
# order-namespace ↔ generate_pack._build_order contract
# --------------------------------------------------------------------------- #


def test_order_namespace_satisfies_build_order():
    """Regression (2026-07-10): `generate_pack._build_order` grew an
    `mcq_bias` attribute the harness's Namespace didn't carry, so every
    validation topic failed at runtime with AttributeError and the run
    produced zero questions. This pins the contract offline: the harness's
    namespace must build a real order, with and without the MCQ bias."""
    import scripts.generate_pack as generate_pack

    for mcq_bias in (False, True):
        order = generate_pack._build_order(
            vg._order_namespace(
                "dev topic", target_count=5, language="en", mcq_bias=mcq_bias
            )
        )
        assert order.target_count == 5
        assert ("MULTIPLE-CHOICE EMPHASIS" in order.prompt) is mcq_bias
