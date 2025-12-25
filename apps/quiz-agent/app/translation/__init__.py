"""Translation module for multilingual quiz support."""

from .translator import TranslationService
from .feedback_messages import get_feedback_message

__all__ = ["TranslationService", "get_feedback_message"]
