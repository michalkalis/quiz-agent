"""#230.1 question audio for a remote room guest.

A guest in another city has no host phone next to them, so their phone must
fetch the same read-aloud audio the host gets, and nothing more: only members,
only the question that is on screen.
"""

from __future__ import annotations

import pytest

from .test_room_play import _h, game  # noqa: F401  (fixture)

pytestmark = pytest.mark.asyncio


class FakeTTS:
    def __init__(self):
        self.texts: list[str] = []

    async def synthesize_question(self, question_text, voice=None):
        self.texts.append(question_text)
        return b"opus-bytes"


async def _audio(game, who, qid="q_mcq", room_id=None):  # noqa: F811
    return await game.c.get(
        f"/api/v1/rooms/{room_id or game.room_id}/question/audio",
        params={"question_id": qid},
        headers=_h(who),
    )


@pytest.fixture
def tts(game):  # noqa: F811
    fake = FakeTTS()
    game.c._transport.app.state.tts_service = fake
    return fake


async def test_guest_member_gets_the_question_audio(game, tts):  # noqa: F811
    """A remote guest hears the question, read from the shared TTS path
    (the MCQ options are part of the spoken text, as for the host)."""
    await game.setup()
    r = await _audio(game, "jana")
    assert r.status_code == 200, r.text
    assert r.content == b"opus-bytes" and r.headers["content-type"] == "audio/opus"
    assert "Which planet has the most moons?" in tts.texts[0]


async def test_host_may_fetch_it_too(game, tts):  # noqa: F811
    """Members are equal here; the host's phone can use the room route as well."""
    await game.setup()
    assert (await _audio(game, "host")).status_code == 200


async def test_stranger_and_unknown_room_get_404(game, tts):  # noqa: F811
    """The audio is the question itself: no leak to non-members, and an
    unknown room looks the same as a foreign one."""
    await game.setup()
    assert (await _audio(game, "stranger")).status_code == 404
    assert (await _audio(game, "jana", room_id="nope")).status_code == 404
    assert tts.texts == []


async def test_stale_question_id_is_409(game, tts):  # noqa: F811
    """No audio of a question the guest can't see (yet or any more)."""
    await game.setup()
    assert (await _audio(game, "jana", qid="q_open")).status_code == 409
    assert tts.texts == []


async def test_lobby_is_409(game, tts):  # noqa: F811
    """Before the game starts there is no question to read."""
    await game.setup(start=False)
    assert (await _audio(game, "jana")).status_code == 409
    assert tts.texts == []
