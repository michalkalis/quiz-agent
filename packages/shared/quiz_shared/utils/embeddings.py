"""Embedding generation and similarity utilities for RAG."""

import numpy as np
from openai import OpenAI
from typing import List, Optional
import os


def generate_embedding(
    text: str,
    model: str = "text-embedding-3-small",
    api_key: Optional[str] = None
) -> List[float]:
    """Generate embedding vector for text using OpenAI.

    Args:
        text: Text to embed
        model: OpenAI embedding model (default: text-embedding-3-small)
        api_key: OpenAI API key (default: from env OPENAI_API_KEY)

    Returns:
        Embedding vector as list of floats

    Example:
        >>> embedding = generate_embedding("What is the capital of France?")
        >>> len(embedding)
        1536
    """
    client = OpenAI(api_key=api_key or os.getenv("OPENAI_API_KEY"))

    response = client.embeddings.create(
        model=model,
        input=text
    )

    return response.data[0].embedding


def calculate_similarity(embedding1: List[float], embedding2: List[float]) -> float:
    """Calculate cosine similarity between two embeddings.

    Args:
        embedding1: First embedding vector
        embedding2: Second embedding vector

    Returns:
        Cosine similarity score (0-1, where 1 is identical)

    Example:
        >>> emb1 = generate_embedding("capital of France")
        >>> emb2 = generate_embedding("what is France's capital")
        >>> similarity = calculate_similarity(emb1, emb2)
        >>> similarity > 0.85  # High similarity
        True
    """
    vec1 = np.array(embedding1)
    vec2 = np.array(embedding2)

    # Cosine similarity
    dot_product = np.dot(vec1, vec2)
    norm1 = np.linalg.norm(vec1)
    norm2 = np.linalg.norm(vec2)

    if norm1 == 0 or norm2 == 0:
        return 0.0

    return float(dot_product / (norm1 * norm2))


def is_duplicate(
    question_text: str,
    existing_embeddings: List[List[float]],
    threshold: float = 0.85
) -> tuple[bool, float]:
    """Check if question is duplicate of existing questions.

    Args:
        question_text: New question text
        existing_embeddings: List of embeddings from existing questions
        threshold: Similarity threshold for duplicate detection (default: 0.85)

    Returns:
        Tuple of (is_duplicate: bool, max_similarity: float)

    Example:
        >>> is_dup, sim = is_duplicate(
        ...     "What's the capital of France?",
        ...     existing_embeddings
        ... )
        >>> if is_dup:
        ...     print(f"Duplicate detected! Similarity: {sim:.2f}")
    """
    if not existing_embeddings:
        return False, 0.0

    question_embedding = generate_embedding(question_text)

    similarities = [
        calculate_similarity(question_embedding, existing_emb)
        for existing_emb in existing_embeddings
    ]

    max_similarity = max(similarities)
    is_dup = max_similarity >= threshold

    return is_dup, max_similarity
