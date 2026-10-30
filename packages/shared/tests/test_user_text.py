"""Player text loses only what nobody can see; pasted content stays intact."""

from quiz_shared.utils.user_text import clean_user_text


def test_pasted_text_with_newlines_emoji_and_diacritics_is_untouched() -> None:
    # A real paste from Notes: lines, tabs, Slovak diacritics, a ZWJ emoji.
    pasted = "Hrady a zámky\n\t• Bojnice 👨‍👩‍👧 <3 > 100 m"
    assert clean_user_text(pasted) == pasted


def test_bidi_override_and_control_chars_are_removed() -> None:
    # U+202E renders "evil" text reversed; NUL/ESC can break logs and storage.
    assert clean_user_text("Ann‮abc‬\x00\x1b[31m") == "Annabc[31m"
    assert clean_user_text("﻿space​ race\r\n") == "space race\n"
