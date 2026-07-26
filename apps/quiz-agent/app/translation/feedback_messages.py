"""Multilingual feedback messages for quiz responses."""

# Feedback messages in different languages
# Format: {language_code: {result: message}}
FEEDBACK_MESSAGES = {
    "en": {
        "correct": "Correct!",
        "incorrect": "Incorrect.",
        "partially_correct": "Partially correct.",
        "partially_incorrect": "Partially incorrect.",
        "skipped": "Skipped.",
    },
    "sk": {  # Slovak
        "correct": "Správne!",
        "incorrect": "Nesprávne.",
        "partially_correct": "Čiastočne správne.",
        "partially_incorrect": "Čiastočne nesprávne.",
        "skipped": "Preskočené.",
    },
    "cs": {  # Czech
        "correct": "Správně!",
        "incorrect": "Nesprávně.",
        "partially_correct": "Částečně správně.",
        "partially_incorrect": "Částečně nesprávně.",
        "skipped": "Přeskočeno.",
    },
    "de": {  # German
        "correct": "Richtig!",
        "incorrect": "Falsch.",
        "partially_correct": "Teilweise richtig.",
        "partially_incorrect": "Teilweise falsch.",
        "skipped": "Übersprungen.",
    },
    "fr": {  # French
        "correct": "Correct!",
        "incorrect": "Incorrect.",
        "partially_correct": "Partiellement correct.",
        "partially_incorrect": "Partiellement incorrect.",
        "skipped": "Sauté.",
    },
    "es": {  # Spanish
        "correct": "¡Correcto!",
        "incorrect": "Incorrecto.",
        "partially_correct": "Parcialmente correcto.",
        "partially_incorrect": "Parcialmente incorrecto.",
        "skipped": "Omitido.",
    },
    "it": {  # Italian
        "correct": "Corretto!",
        "incorrect": "Sbagliato.",
        "partially_correct": "Parzialmente corretto.",
        "partially_incorrect": "Parzialmente sbagliato.",
        "skipped": "Saltato.",
    },
    "pl": {  # Polish
        "correct": "Poprawnie!",
        "incorrect": "Niepoprawnie.",
        "partially_correct": "Częściowo poprawnie.",
        "partially_incorrect": "Częściowo niepoprawnie.",
        "skipped": "Pominięte.",
    },
    "hu": {  # Hungarian
        "correct": "Helyes!",
        "incorrect": "Helytelen.",
        "partially_correct": "Részben helyes.",
        "partially_incorrect": "Részben helytelen.",
        "skipped": "Kihagyva.",
    },
    "ro": {  # Romanian
        "correct": "Corect!",
        "incorrect": "Incorect.",
        "partially_correct": "Parțial corect.",
        "partially_incorrect": "Parțial incorect.",
        "skipped": "Sărit.",
    },
}


# Feedback templates with correct answer placeholder
# Used when answer is incorrect/partially correct
CORRECT_ANSWER_TEMPLATES = {
    "en": {
        "correct": "Correct! The answer is {answer}.",
        "incorrect": "Incorrect. The correct answer is {answer}.",
        "partially_correct": "Partially correct. The correct answer is {answer}.",
        "partially_incorrect": "Partially incorrect. The correct answer is {answer}.",
    },
    "sk": {  # Slovak
        "correct": "Správne! Odpoveď je {answer}.",
        "incorrect": "Nesprávne. Správna odpoveď je {answer}.",
        "partially_correct": "Čiastočne správne. Správna odpoveď je {answer}.",
        "partially_incorrect": "Čiastočne nesprávne. Správna odpoveď je {answer}.",
    },
    "cs": {  # Czech
        "correct": "Správně! Odpověď je {answer}.",
        "incorrect": "Nesprávně. Správná odpověď je {answer}.",
        "partially_correct": "Částečně správně. Správná odpověď je {answer}.",
        "partially_incorrect": "Částečně nesprávně. Správná odpověď je {answer}.",
    },
    "de": {  # German
        "correct": "Richtig! Die Antwort ist {answer}.",
        "incorrect": "Falsch. Die richtige Antwort ist {answer}.",
        "partially_correct": "Teilweise richtig. Die richtige Antwort ist {answer}.",
        "partially_incorrect": "Teilweise falsch. Die richtige Antwort ist {answer}.",
    },
    "fr": {  # French
        "correct": "Correct! La réponse est {answer}.",
        "incorrect": "Incorrect. La bonne réponse est {answer}.",
        "partially_correct": "Partiellement correct. La bonne réponse est {answer}.",
        "partially_incorrect": "Partiellement incorrect. La bonne réponse est {answer}.",
    },
    "es": {  # Spanish
        "correct": "¡Correcto! La respuesta es {answer}.",
        "incorrect": "Incorrecto. La respuesta correcta es {answer}.",
        "partially_correct": "Parcialmente correcto. La respuesta correcta es {answer}.",
        "partially_incorrect": "Parcialmente incorrecto. La respuesta correcta es {answer}.",
    },
    "it": {  # Italian
        "correct": "Corretto! La risposta è {answer}.",
        "incorrect": "Sbagliato. La risposta corretta è {answer}.",
        "partially_correct": "Parzialmente corretto. La risposta corretta è {answer}.",
        "partially_incorrect": "Parzialmente sbagliato. La risposta corretta è {answer}.",
    },
    "pl": {  # Polish
        "correct": "Poprawnie! Odpowiedź to {answer}.",
        "incorrect": "Niepoprawnie. Poprawna odpowiedź to {answer}.",
        "partially_correct": "Częściowo poprawnie. Poprawna odpowiedź to {answer}.",
        "partially_incorrect": "Częściowo niepoprawnie. Poprawna odpowiedź to {answer}.",
    },
    "hu": {  # Hungarian
        "correct": "Helyes! A válasz: {answer}.",
        "incorrect": "Helytelen. A helyes válasz: {answer}.",
        "partially_correct": "Részben helyes. A helyes válasz: {answer}.",
        "partially_incorrect": "Részben helytelen. A helyes válasz: {answer}.",
    },
    "ro": {  # Romanian
        "correct": "Corect! Răspunsul este {answer}.",
        "incorrect": "Incorect. Răspunsul corect este {answer}.",
        "partially_correct": "Parțial corect. Răspunsul corect este {answer}.",
        "partially_incorrect": "Parțial incorect. Răspunsul corect este {answer}.",
    },
}


# Spoken lead-in before a multiple-choice option read-out
# ("… how many Earth days? Options. A: ten. B: one hundred.")
OPTIONS_LABEL = {
    "en": "Options",
    "sk": "Možnosti",  # Slovak
    "cs": "Možnosti",  # Czech
    "de": "Optionen",  # German
    "fr": "Options",  # French
    "es": "Opciones",  # Spanish
    "it": "Opzioni",  # Italian
    "pl": "Opcje",  # Polish
    "hu": "Lehetőségek",  # Hungarian
    "ro": "Opțiuni",  # Romanian
}


# Spoken name of an option key, for languages where the bare letter misreads.
# Slovak/Czech TTS says a standalone "A" as the conjunction *a* ("and"), which
# is both wrong mid-sentence and prompts the driver to answer "a"; the
# letter-names below are exactly the vocabulary the iOS MCQTranscriptMatcher
# accepts back. Languages absent here speak the uppercase letter.
OPTION_LETTER_NAMES = {
    "sk": {"a": "Áčko", "b": "Béčko", "c": "Céčko", "d": "Déčko"},
    "cs": {"a": "Áčko", "b": "Béčko", "c": "Céčko", "d": "Déčko"},
}


def get_feedback_message(result: str, language: str = "en") -> str:
    """Get feedback message in specified language.

    Args:
        result: Evaluation result (correct, incorrect, etc.)
        language: ISO 639-1 language code

    Returns:
        Localized feedback message
    """
    # Get language-specific messages, fallback to English
    messages = FEEDBACK_MESSAGES.get(language, FEEDBACK_MESSAGES["en"])

    # Get specific message, fallback to result itself
    return messages.get(result, result.replace("_", " ").title())


def get_correct_answer_message(result: str, answer: str, language: str = "en") -> str:
    """Get feedback message with correct answer in specified language.

    Args:
        result: Evaluation result (incorrect, partially_correct, partially_incorrect)
        answer: The correct answer to announce
        language: ISO 639-1 language code

    Returns:
        Localized feedback message with answer inserted
    """
    # Get language-specific templates, fallback to English
    templates = CORRECT_ANSWER_TEMPLATES.get(language, CORRECT_ANSWER_TEMPLATES["en"])

    # Get specific template, fallback to generic
    template = templates.get(result)
    if not template:
        return f"The correct answer is {answer}."

    # Sanitize answer for TTS (remove control chars, limit length)
    clean_answer = answer.strip()
    if len(clean_answer) > 100:
        clean_answer = clean_answer[:97] + "..."

    return template.format(answer=clean_answer)


def get_options_label(language: str = "en") -> str:
    """Get the spoken "Options" lead-in in the specified language.

    Args:
        language: ISO 639-1 language code

    Returns:
        Localized label, English fallback for unsupported languages
    """
    return OPTIONS_LABEL.get(language, OPTIONS_LABEL["en"])


def get_option_letter(key: str, language: str = "en") -> str:
    """Get the spoken name of a multiple-choice option key ("a" → "Áčko").

    Args:
        key: Option key from ``Question.possible_answers``
        language: ISO 639-1 language code

    Returns:
        Localized letter name, or the uppercase key where the letter reads fine
    """
    names = OPTION_LETTER_NAMES.get(language, {})
    return names.get(key.lower(), key.upper())
