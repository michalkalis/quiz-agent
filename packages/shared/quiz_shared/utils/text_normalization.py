"""Text normalization utilities for answer comparison.

Extracted from graph.py:59-64
"""

import re


def normalize_text(text: str) -> str:
    """Normalize text for comparison.

    Removes punctuation, extra whitespace, and converts to lowercase.
    Useful for fuzzy answer matching.

    Args:
        text: Text to normalize

    Returns:
        Normalized text

    Example:
        >>> normalize_text("Paris, France!")
        'paris france'
        >>> normalize_text("  London  ")
        'london'
    """
    text = text.lower().strip()
    text = re.sub(r'[.,!?;:\'"()-]', '', text)
    text = re.sub(r'\s+', ' ', text)
    return text
