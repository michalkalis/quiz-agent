"""Generate verbal question text for country silhouettes using an LLM."""

import json
from pathlib import Path
from typing import Optional

from openai import OpenAI

PROMPT_PATH = (
    Path(__file__).parent.parent.parent / "prompts" / "question_generation_silhouette.md"
)


def generate_silhouette_question_text(
    country_name: str,
    difficulty: str,
    model: str = "gpt-4o",
) -> dict:
    """Generate verbal question text and metadata for a silhouette question.

    Args:
        country_name: Name of the country.
        difficulty: easy | medium | hard.
        model: OpenAI model to use.

    Returns:
        Dict with keys: question, alternative_answers, tags, explanation.
    """
    client = OpenAI()

    prompt_template = PROMPT_PATH.read_text()
    prompt = prompt_template.format(
        country_name=country_name,
        difficulty=difficulty,
    )

    response = client.chat.completions.create(
        model=model,
        max_tokens=1024,
        messages=[{"role": "user", "content": prompt}],
    )

    text = response.choices[0].message.content
    # Extract JSON from response
    start = text.find("{")
    end = text.rfind("}") + 1
    if start == -1 or end == 0:
        raise ValueError(f"No JSON found in response: {text[:200]}")

    return json.loads(text[start:end])


def build_silhouette_question(
    country_name: str,
    difficulty: str,
    media_url: str,
    reveal_url: Optional[str] = None,
    llm_data: Optional[dict] = None,
    model: str = "gpt-4o",
) -> dict:
    """Build a complete question dict ready for import.

    Args:
        country_name: Name of the country.
        difficulty: easy | medium | hard.
        media_url: Public URL of the silhouette image.
        reveal_url: Public URL of the labeled silhouette (for reveal).
        llm_data: Pre-generated LLM data (if None, calls the LLM).
        model: OpenAI model for question text generation.

    Returns:
        Dict matching the Question model schema.
    """
    if llm_data is None:
        llm_data = generate_silhouette_question_text(country_name, difficulty, model)

    generation_metadata = {
        "image_generator": "geopandas_silhouette",
        "country": country_name,
    }
    if reveal_url:
        generation_metadata["reveal_url"] = reveal_url

    return {
        "question": llm_data["question"],
        "type": "image",
        "image_subtype": "silhouette",
        "correct_answer": country_name,
        "alternative_answers": llm_data.get("alternative_answers", []),
        "topic": "Geography",
        "category": "adults",
        "difficulty": difficulty,
        "tags": llm_data.get("tags", ["geography", "countries", "silhouettes"]),
        "language_dependent": False,
        "media_url": media_url,
        "explanation": llm_data.get("explanation"),
        "generation_metadata": generation_metadata,
    }
