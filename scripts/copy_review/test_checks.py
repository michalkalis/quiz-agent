"""Why these checks matter (#231 — Ukrainian as a fourth language): the main
audience is the Ukrainian App Store, where a Russian letter or a Latin lookalike
inside a Cyrillic word reads as careless or as Russian, and the player is
addressed with «ти» like in sk/cs, while legal pages stay formal.
Run: python3 -m unittest scripts.copy_review.test_checks
"""

import unittest

from scripts.copy_review.checks import check, text_flags


def rules(lang, text, legal=False):
    return {rule for rule, _, _ in text_flags(lang, text, legal)}


def errors(lang, text):
    return [note for _, note, error in text_flags(lang, text) if error]


def row(**langs):
    return {"id": "Localizable:x", "comment": "", "stale": False, "en": "Start", "sk": "Štart", "cs": "Start", **langs}


class UkrainianChecks(unittest.TestCase):
    def test_clean_informal_text_passes(self):
        self.assertEqual(text_flags("uk", "Скажи відповідь або натисни «Ще раз»."), [])

    def test_russian_letters_are_errors(self):
        # «Объявление», «Это», «ещё» are Russian; Ukrainian has none of ы э ъ ё.
        for text in ("Обычная викторина", "Это вопрос", "Ещё раз", "Подъезд"):
            self.assertTrue(errors("uk", text), text)

    def test_latin_lookalike_inside_cyrillic_word_is_an_error(self):
        # Latin "i" in «відповідь» looks right but breaks search and the voice.
        self.assertTrue(errors("uk", "Твоя вiдповiдь"))
        # Brand names in Latin next to Cyrillic words are fine.
        self.assertEqual(errors("uk", "Trubbo у App Store на iPhone"), [])

    def test_formal_address_is_flagged_outside_legal(self):
        self.assertIn(1, rules("uk", "Ваша відповідь правильна"))
        self.assertIn(1, rules("uk", "Дякуємо, що Ви граєте"))
        self.assertIn(1, rules("uk", "Спробуйте ще раз"))  # plural/polite imperative
        self.assertIn(1, rules("uk", "Натисніть, щоб почати"))
        self.assertNotIn(1, rules("uk", "Спробуй ще раз"))

    def test_legal_pages_may_be_formal(self):
        self.assertNotIn(1, rules("uk", "Ми обробляємо ваші дані, щоб надати вам послугу.", legal=True))
        # ...but still no Russian letters there.
        self.assertIn(24, rules("uk", "Ваши данные", legal=True))

    def test_dash_as_punctuation_is_flagged(self):
        self.assertIn(5, rules("uk", "Київ — столиця України"))
        self.assertNotIn(5, rules("uk", "Варіанти 1–4"))

    def test_lowercase_formal_address_is_flagged(self):
        for text in ("Якщо ви не бачиш кнопку", "Ми надішлемо вам лист"):
            self.assertIn(1, rules("uk", text), text)
        self.assertNotIn(1, rules("uk", "Якщо ти не бачиш кнопку"))
        self.assertNotIn(1, rules("uk", "Вашингтон — не столиця"))  # a city, not «ваш»
        self.assertNotIn(1, rules("uk", "Ми надішлемо вам лист", legal=True))  # rule 21: legal «ви»

    def test_short_plural_imperatives_are_flagged(self):
        for text in ("Дайте доступ до мікрофона", "Ідіть далі"):
            self.assertIn(1, rules("uk", text), text)

    def test_third_person_verb_is_not_an_imperative(self):
        self.assertNotIn(1, rules("uk", "Стоїть на паузі"))

    def test_infinitive_button_is_flagged_but_not_running_text_or_questions(self):
        self.assertIn(22, rules("uk", "Підтвердити"))
        self.assertIn(22, rules("uk", "Видалити акаунт"))
        for text in ("Підтверди", "Пропусти", "Спробуй ще раз", "Видалити акаунт?", "Видали мої дані",
                     "Можна підтвердити відповідь голосом"):
            self.assertNotIn(22, rules("uk", text), text)

    def test_russian_words_without_russian_letters_are_errors(self):
        for text in ("Настройки", "Начать игру", "Киев"):
            self.assertTrue(errors("uk", text), text)
        self.assertEqual(errors("uk", "Налаштування"), [])
        self.assertEqual(errors("uk", "Київ"), [])

    def test_quiz_run_is_a_viktoryna_not_a_session(self):
        flags = check(row(uk="Почати сесію"))
        self.assertIn(7, {f["rule"] for f in flags if f["lang"] == "uk"})
        self.assertNotIn(7, {f["rule"] for f in check(row(uk="Почати вікторину")) if f["lang"] == "uk"})
        self.assertNotIn(7, {f["rule"] for f in check(row(uk="Сесія закінчилась. Увійди ще раз.")) if f["lang"] == "uk"})

    def test_contrast_tail_in_ukrainian(self):
        self.assertIn(12, rules("uk", "Це вікторина, а не іспит"))
        self.assertIn(12, rules("uk", "Не лише для авто"))
        self.assertNotIn(12, rules("uk", "Це вікторина для дороги"))

    def test_sk_cs_formal_checks_unchanged(self):
        self.assertIn(1, rules("sk", "Skúste znova"))
        self.assertIn(1, rules("cs", "Váš výsledek"))
        self.assertNotIn(1, rules("sk", "Skús znova"))


class RowChecks(unittest.TestCase):
    def test_row_translated_for_some_languages_only_is_an_error(self):
        # #905 and #907 merged with sk/cs texts and no uk: a Ukrainian player would read English.
        flags = check(row())
        self.assertIn(("uk", 8, "missing translation", True), {(f["lang"], f["rule"], f["note"], f["error"]) for f in flags})

    def test_row_with_no_translation_at_all_is_not_an_error(self):
        # Symbols, debug labels and names stay English on purpose; only a partly translated row blocks.
        flags = check(row(sk=None, cs=None))
        self.assertEqual([f for f in flags if f["error"]], [])

    def test_ukrainian_count_needs_plural_variants(self):
        flags = check(row(en={"one": "%lld question", "other": "%lld questions"}, sk=None, cs=None, uk="%lld питань"))
        self.assertIn(6, {f["rule"] for f in flags if f["lang"] == "uk"})

    def test_russian_letter_in_row_is_marked_as_error(self):
        flags = check(row(uk="Ещё раз"))
        self.assertTrue(any(f["error"] and f["lang"] == "uk" for f in flags))
        self.assertFalse(any(f["error"] for f in check(row(uk="Старт"))))


if __name__ == "__main__":
    unittest.main()
