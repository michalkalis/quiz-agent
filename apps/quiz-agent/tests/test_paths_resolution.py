"""Regression tests for repo-path resolution that must survive the Docker layout
(issue #60.P3, the structural fix for the #70 twin).

WHY this matters -- not just what it does: alembic ``env.py`` in both apps and
the quiz-pack-api ARQ worker locate repo files by walking up from ``__file__``.
The previous code indexed a *fixed* number of parent levels (``parents[3]`` /
``parents[4]``). That index is valid only for the local checkout; inside the
Docker image the app is copied to ``/app``, which has fewer parent levels, so
the fixed index raised ``IndexError``. Because the ``.env`` lookup runs
unconditionally at import time, that ``IndexError`` crashed in-container
``alembic upgrade head`` in both apps. The contract these tests pin: a walk that
runs out of parents must terminate gracefully (never raise) so in-container
migrations boot regardless of how deep the code is mounted, and must degrade to
a no-op (returning ``None``) when the target is absent in the ``/app`` layout.
"""

import os

from quiz_shared.paths import find_in_ancestors, load_dotenv_from_ancestors


def test_finds_closest_target_walking_up(tmp_path):
    """A target one or more levels above the module is found via the walk."""
    (tmp_path / ".env").write_text("X=1\n")
    module = tmp_path / "apps" / "svc" / "alembic" / "env.py"
    module.parent.mkdir(parents=True)

    assert find_in_ancestors(module, ".env") == tmp_path / ".env"


def test_prefers_nearest_when_multiple_ancestors_match(tmp_path):
    """Walk returns the CLOSEST ancestor's copy, not the farthest -- the same
    "nearest .env wins" semantics the old fixed-depth load relied on."""
    (tmp_path / ".env").write_text("X=far\n")
    near = tmp_path / "apps"
    near.mkdir()
    (near / ".env").write_text("X=near\n")
    module = near / "svc" / "alembic" / "env.py"
    module.parent.mkdir(parents=True)

    assert find_in_ancestors(module, ".env") == near / ".env"


def test_docker_app_layout_does_not_raise_and_returns_none(tmp_path):
    """THE #60.P3 / #70 regression: a shallow ``/app``-style module with no
    ``.env`` above it. The old ``parents[N]`` indexing raised ``IndexError``
    here and crashed in-container ``alembic upgrade head``. The walk must
    instead terminate and report "not found" so the bootstrap falls through to
    OS environment variables. (``tmp_path`` lives under the OS temp tree, which
    has no ``.env`` ancestor -- the isolated stand-in for the ``/app`` mount.)"""
    module = tmp_path / "app" / "alembic" / "env.py"
    module.parent.mkdir(parents=True)

    # No exception (the bug) + graceful no-op for both the primitive and the
    # dotenv wrapper used on the migration bootstrap path.
    assert find_in_ancestors(module, ".env") is None
    assert load_dotenv_from_ancestors(module) is None


def test_loads_discovered_env_without_overriding_preset(tmp_path, monkeypatch):
    """The env.py call site must actually load the discovered ``.env`` AND keep
    ``override=False`` -- a value already in the OS environment wins, matching
    the prior behavior so a real Fly secret is never clobbered by a stray file."""
    (tmp_path / ".env").write_text("QUIZ_P3_FRESH=fromfile\nQUIZ_P3_PRESET=fromfile\n")
    module = tmp_path / "apps" / "svc" / "alembic" / "env.py"
    module.parent.mkdir(parents=True)

    monkeypatch.delenv("QUIZ_P3_FRESH", raising=False)
    monkeypatch.setenv("QUIZ_P3_PRESET", "fromenv")

    assert load_dotenv_from_ancestors(module) == tmp_path / ".env"
    assert os.environ["QUIZ_P3_FRESH"] == "fromfile"  # newly loaded from the file
    assert os.environ["QUIZ_P3_PRESET"] == "fromenv"  # pre-set var NOT overridden
