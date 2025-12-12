"""Utility functions for quiz system."""

from .text_normalization import normalize_text
from .embeddings import generate_embedding, calculate_similarity

__all__ = ["normalize_text", "generate_embedding", "calculate_similarity"]
