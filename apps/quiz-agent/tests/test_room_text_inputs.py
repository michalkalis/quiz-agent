"""Names and typed answers in "play together" are shown to the other players.

So what the server keeps must be what everyone sees: a name that reverses
itself with a bidi override, spans several lines or is only blank space could
impersonate another player or break the lobby; a blank answer would be an
empty row on everyone's reveal screen.
"""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from app.api.routes.room_play import AnswerRequest
from app.api.routes.rooms import CreateRoomRequest, JoinRoomRequest


def test_name_is_one_visible_line() -> None:
    body = JoinRoomRequest(display_name=" Mi‮chal\n\t Kališ 🎉 ")
    assert body.display_name == "Michal Kališ 🎉"


@pytest.mark.parametrize("name", ["   ", "‮​", "x" * 25])
def test_blank_or_too_long_name_is_rejected(name: str) -> None:
    with pytest.raises(ValidationError):
        CreateRoomRequest(session_id="s", host_name=name)


def test_typed_answer_keeps_its_text_without_invisible_characters() -> None:
    body = AnswerRequest(question_id="q", answer="  Westphalia‮ 1648 ")
    assert body.answer == "Westphalia 1648"


def test_blank_answer_is_rejected() -> None:
    with pytest.raises(ValidationError):
        AnswerRequest(question_id="q", answer=" ​ ")
