"""TTS digit→words normalization (founder bug 2026-07-12).

Why this matters: OpenAI tts-1 auto-detects language from the input text and
has no locale parameter — digits embedded in Slovak text get English
pronunciation. The fix spells numbers out in the target language before
synthesis; these tests pin that transform (and its fail-safe passthroughs) so
a regression here re-breaks Slovak audio, not just formatting.
"""

from app.tts.number_normalization import normalize_numbers_for_tts


class TestSlovakNormalization:
    def test_year_is_spelled_out(self):
        assert (
            normalize_numbers_for_tts("V roku 1969 pristáli na Mesiaci.", "sk")
            == "V roku tisícdeväťstošesťdesiatdeväť pristáli na Mesiaci."
        )

    def test_comma_thousands_separator(self):
        assert (
            normalize_numbers_for_tts("Má 24,000 rokov.", "sk")
            == "Má dvadsaťštyritisíc rokov."
        )

    def test_space_thousands_separator(self):
        assert (
            normalize_numbers_for_tts("Má 24 000 rokov.", "sk")
            == "Má dvadsaťštyritisíc rokov."
        )

    def test_decimal_number(self):
        out = normalize_numbers_for_tts("Pí je približne 3,14.", "sk")
        assert "tri celých štrnásť" in out
        assert "3,14" not in out

    def test_percent_becomes_word(self):
        out = normalize_numbers_for_tts("Až 42 % povrchu.", "sk")
        assert out == "Až štyridsaťdva percent povrchu."

    def test_adjacent_numbers_do_not_merge(self):
        out = normalize_numbers_for_tts("Čísla 1969 a 12.", "sk")
        assert "tisícdeväťstošesťdesiatdeväť" in out
        assert "dvanásť" in out


class TestPassthrough:
    def test_english_text_unchanged(self):
        text = "In 1969, humans landed on the Moon."
        assert normalize_numbers_for_tts(text, "en") == text

    def test_unsupported_language_unchanged(self):
        text = "V roku 1969."
        assert normalize_numbers_for_tts(text, "de") == text

    def test_text_without_digits_unchanged(self):
        text = "Ktorá rieka je najdlhšia?"
        assert normalize_numbers_for_tts(text, "sk") == text
