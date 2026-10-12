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


class TestOrdinals:
    """#200: "N." before a word is an ordinal in sk/cs, declined by context.

    The cardinal pass used to read it as a cardinal AND keep the period —
    "v devätnásť. storočí", "jeden. mája" — a wrong word plus a sentence-end
    pause mid-question, on every TTS voice. num2words has no sk/cs ordinals.
    """

    def test_slovak_century_in_the_locative(self):
        assert (
            normalize_numbers_for_tts("Žil v 19. storočí.", "sk")
            == "Žil v devätnástom storočí."
        )

    def test_slovak_date_in_the_genitive(self):
        assert (
            normalize_numbers_for_tts("Vojna skončila 1. mája 1945.", "sk")
            == "Vojna skončila prvého mája tisícdeväťstoštyridsaťpäť."
        )

    def test_czech_century_takes_its_case_from_the_preposition(self):
        # "století" looks the same in every singular case but the instrumental.
        assert (
            normalize_numbers_for_tts("Žil v 19. století.", "cs")
            == "Žil v devatenáctém století."
        )
        assert (
            normalize_numbers_for_tts("Je to 19. století.", "cs")
            == "Je to devatenácté století."
        )

    def test_czech_date_in_the_genitive(self):
        assert (
            normalize_numbers_for_tts("Válka skončila 1. května 1945.", "cs")
            == "Válka skončila prvního května tisíc devětset čtyřicet pět."
        )

    def test_case_follows_the_century_noun(self):
        cases = {
            "Je to 20. storočie.": "Je to dvadsiate storočie.",
            "Začiatkom 20. storočia.": "Začiatkom dvadsiateho storočia.",
            "Pred 19. storočím.": "Pred devätnástym storočím.",
            "Je to 21. storočie.": "Je to dvadsiate prvé storočie.",
        }
        for text, spoken in cases.items():
            assert normalize_numbers_for_tts(text, "sk") == spoken

    def test_compound_day_and_numeric_date(self):
        assert (
            normalize_numbers_for_tts("Bolo to 31. decembra 2025.", "sk")
            == "Bolo to tridsiateho prvého decembra dvetisícdvadsaťpäť."
        )
        assert (
            normalize_numbers_for_tts("Vznikla 28. 10. 1918.", "cs")
            == "Vznikla dvacátého osmého října tisíc devětset osmnáct."
        )
        # A date earlier in the text must not shift where later ordinals look.
        assert (
            normalize_numbers_for_tts("Od 1. 1. 2026 v 19. storočí.", "sk")
            == "Od prvého januára dvetisícdvadsaťšesť v devätnástom storočí."
        )

    def test_an_adjective_after_the_ordinal_sets_its_case(self):
        assert (
            normalize_numbers_for_tts("Po 1. a 2. svetovej vojne.", "sk")
            == "Po prvej a druhej svetovej vojne."
        )
        assert (
            normalize_numbers_for_tts("Během 2. světové války.", "cs")
            == "Během druhé světové války."
        )

    def test_unknown_context_is_still_a_word_never_number_period(self):
        for text in ("Je to 7. hrad.", "Je to 150. výročie."):
            out = normalize_numbers_for_tts(text, "sk")
            assert not any(ch.isdigit() for ch in out)
            assert ". " not in out  # no sentence-end pause mid-sentence
        assert normalize_numbers_for_tts("Je to 7. hrad.", "sk") == (
            "Je to siedmy hrad."
        )

    def test_a_number_ending_a_sentence_stays_a_cardinal(self):
        assert (
            normalize_numbers_for_tts("Mal 5. Potom 6.", "sk") == "Mal päť. Potom šesť."
        )

    def test_mcq_options_read_with_key_labels_are_not_ordinals(self):
        # Legacy clients hear "a: 5. b: 7." — the "b" is a label, not a noun.
        assert (
            normalize_numbers_for_tts("Koľko? a: 5. b: 7.", "sk")
            == "Koľko? a: päť. b: sedem."
        )


class TestCardinalsStayAsTheyWere:
    """The founder's report was about the fallback voice, not these forms:
    the glued cardinals read fine on ElevenLabs and must not change (#200)."""

    def test_years(self):
        assert normalize_numbers_for_tts("1918, 2025, 2026", "sk") == (
            "tisícdeväťstoosemnásť, dvetisícdvadsaťpäť, dvetisícdvadsaťšesť"
        )
        assert normalize_numbers_for_tts("1918, 2025, 2026", "cs") == (
            "tisíc devětset osmnáct, dva tisíce dvacet pět, dva tisíce dvacet šest"
        )

    def test_amounts_with_a_magnitude_word(self):
        assert (
            normalize_numbers_for_tts("Približne 200 tisíc", "sk")
            == "Približne dvesto tisíc"
        )
        assert normalize_numbers_for_tts("2 milióny", "sk") == "dva milióny"
        assert (
            normalize_numbers_for_tts("Přibližně 200 tisíc", "cs")
            == "Přibližně dvěstě tisíc"
        )
        assert normalize_numbers_for_tts("2 miliony", "cs") == "dva miliony"
