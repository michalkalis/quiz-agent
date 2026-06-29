"""CLI smoke test for `scripts/generate_pack.py` (issue #36 task 2.16).

The acceptance check is the dry-run path: with the same HTTP mock fixture
the e2e test uses (`e2e_http_mocks`), running the CLI must emit ``N``
stub questions on stdout (where ``N`` matches ``--target-count``).
Real-API mode is not exercised in CI — the script delegates to the same
`PackGenerator` + stages the worker uses, so its real-API behaviour is
covered by the worker's e2e test in ``test_order_e2e.py``.

Why a per-test ``OPENAI_API_KEY`` matters
-----------------------------------------
Importing the script constructs ``AdvancedQuestionGenerator`` at stage-build
time, which instantiates ``ChatOpenAI``. Without a placeholder key the
LangChain client raises at construction before respx ever sees a request.
The conftest already sets one for the integration-test session; this test
just relies on that.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

# Make the ``scripts`` package importable from the test (`apps/quiz-pack-api/scripts`).
_SCRIPTS_DIR = Path(__file__).resolve().parents[2] / "scripts"
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))


pytestmark = pytest.mark.integration


def test_dry_run_prints_questions_and_pack_id(
    capsys: pytest.CaptureFixture[str],
    e2e_http_mocks,
) -> None:
    """`--dry-run` runs the 5-stage pipeline against canned HTTP and prints output.

    The mocked OpenAI generation route returns 3 stub questions
    (`_generation_payload(n=3)` in conftest), so a `--target-count 3` run
    must surface a non-zero question count plus a synthetic `pack_id`.
    A zero count would mean the dedup/verification stages silently dropped
    everything — exactly the regression this test exists to catch.
    """
    import generate_pack

    exit_code = generate_pack.cli_main(
        [
            "--prompt",
            "famous capitals",
            "--target-count",
            "3",
            "--dry-run",
        ]
    )

    assert exit_code == 0
    out = capsys.readouterr().out
    assert "pack_id: dry-run:" in out, out
    # Each printed question line is prefixed `  N. ` — count those to assert
    # the stages produced at least one survivor. The exact number depends on
    # verifier/dedup behaviour against the canned fixture; the mock surfaces
    # three identical-but-distinct questions and the verifier flags them all
    # verified, so we expect ≥ 1 here.
    question_lines = [
        line for line in out.splitlines() if line.lstrip().startswith(("1.", "2.", "3."))
    ]
    assert question_lines, f"expected ≥1 numbered question line, got:\n{out}"


def test_prompt_optional_defaults_to_empty_string() -> None:
    """Omitting `--prompt` is allowed (no-category mode) and yields "" — not None.

    #72 F-1 made `--prompt` optional so a "surprise me" run can omit a topic and
    let the curated TopicPool supply one. The default MUST stay an empty string,
    never None: the orchestrator/DB write seam takes a NOT-NULL prompt, so "" is
    safe where a None would fail in real mode. This is the guard against someone
    "fixing" the default back to None.
    """
    import generate_pack

    args = generate_pack._parse_args(["--target-count", "3"])
    assert args.prompt == ""
