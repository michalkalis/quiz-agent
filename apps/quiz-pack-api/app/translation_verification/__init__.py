"""Translation verification gate for #168 — batch translation pipeline SK/CS.

Pure functions of ``(source_question, translated_draft, language)`` called by
the corpus-translation runner's ``verify`` subcommand only — deliberately NOT
an orchestrator stage (DD12): pack generation and corpus translation are
different pipelines.
"""

from app.translation_verification.draft import TranslatedDraft

__all__ = ["TranslatedDraft"]
