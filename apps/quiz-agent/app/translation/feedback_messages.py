"""Multilingual feedback messages for quiz responses."""

# Feedback messages in different languages
# Format: {language_code: {result: message}}
FEEDBACK_MESSAGES = {
    "en": {
        "correct": "Correct!",
        "incorrect": "Incorrect.",
        "partially_correct": "Partially correct.",
        "partially_incorrect": "Partially incorrect.",
        "skipped": "Skipped."
    },
    "sk": {  # Slovak
        "correct": "Správne!",
        "incorrect": "Nesprávne.",
        "partially_correct": "Čiastočne správne.",
        "partially_incorrect": "Čiastočne nesprávne.",
        "skipped": "Preskočené."
    },
    "cs": {  # Czech
        "correct": "Správně!",
        "incorrect": "Nesprávně.",
        "partially_correct": "Částečně správně.",
        "partially_incorrect": "Částečně nesprávně.",
        "skipped": "Přeskočeno."
    },
    "de": {  # German
        "correct": "Richtig!",
        "incorrect": "Falsch.",
        "partially_correct": "Teilweise richtig.",
        "partially_incorrect": "Teilweise falsch.",
        "skipped": "Übersprungen."
    },
    "fr": {  # French
        "correct": "Correct!",
        "incorrect": "Incorrect.",
        "partially_correct": "Partiellement correct.",
        "partially_incorrect": "Partiellement incorrect.",
        "skipped": "Sauté."
    },
    "es": {  # Spanish
        "correct": "¡Correcto!",
        "incorrect": "Incorrecto.",
        "partially_correct": "Parcialmente correcto.",
        "partially_incorrect": "Parcialmente incorrecto.",
        "skipped": "Omitido."
    },
    "it": {  # Italian
        "correct": "Corretto!",
        "incorrect": "Sbagliato.",
        "partially_correct": "Parzialmente corretto.",
        "partially_incorrect": "Parzialmente sbagliato.",
        "skipped": "Saltato."
    },
    "pl": {  # Polish
        "correct": "Poprawnie!",
        "incorrect": "Niepoprawnie.",
        "partially_correct": "Częściowo poprawnie.",
        "partially_incorrect": "Częściowo niepoprawnie.",
        "skipped": "Pominięte."
    },
    "hu": {  # Hungarian
        "correct": "Helyes!",
        "incorrect": "Helytelen.",
        "partially_correct": "Részben helyes.",
        "partially_incorrect": "Részben helytelen.",
        "skipped": "Kihagyva."
    },
    "ro": {  # Romanian
        "correct": "Corect!",
        "incorrect": "Incorect.",
        "partially_correct": "Parțial corect.",
        "partially_incorrect": "Parțial incorect.",
        "skipped": "Sărit."
    }
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
