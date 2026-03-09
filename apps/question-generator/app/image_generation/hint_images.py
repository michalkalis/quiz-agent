"""Agentic pipeline for AI-generated hint images.

Uses metonymy to create visual clues that hint at the answer without revealing it.
Pipeline: LLM prompt → image generation → vision validation → retry loop.
"""

import base64
import io
import json
import os
from pathlib import Path
from typing import Optional

from openai import OpenAI

# Parameterized image model — verify at implementation time
IMAGE_MODEL = os.environ.get("IMAGE_MODEL", "gpt-image-1")
VALIDATION_MODEL = "gpt-4o-mini"
QUESTION_MODEL = "gpt-4o"

MAX_RETRIES = 3


def _get_openai_client() -> OpenAI:
    return OpenAI()


def generate_hint_image_prompt(
    topic: str,
    correct_answer: str,
    difficulty: str,
) -> dict:
    """Stage 1: Generate question text + image prompt using metonymy.

    Returns dict with: question, image_prompt, alternative_answers, tags, explanation.
    """
    client = _get_openai_client()

    system_prompt = """You are generating a visual riddle quiz question. The player will see an AI-generated image and must guess what it represents.

RULES:
- Use METONYMY: show associated objects/scenes, never the thing itself
- The image should contain 2-3 visual clues (not 1 = random guessing, not 5+ = too easy)
- NEVER include the answer in the image prompt
- Art style: oil painting or editorial illustration
- Image prompt must avoid trigger words: "book", "cover", "poster", "sign", "title", "logo", "text", "words", "letters"
- End every image prompt with: "No text, no words, no letters, no writing anywhere in the image."
- The question text must be answerable via TTS (voice-only mode) for a knowledgeable player"""

    user_prompt = f"""Generate a visual riddle question about:
- Topic: {topic}
- Correct answer: {correct_answer}
- Difficulty: {difficulty}

Return a JSON object with these fields:
{{
  "question": "This atmospheric painting hints at [topic description]. What is it?",
  "image_prompt": "Oil painting of [2-3 visual clues using metonymy]. No text, no words, no letters, no writing anywhere in the image.",
  "alternative_answers": ["alternative name 1"],
  "tags": ["topic-tag", "hint-image"],
  "explanation": "The image shows [explain the visual clues and their connection to the answer]."
}}

Return ONLY the JSON object."""

    response = client.chat.completions.create(
        model=QUESTION_MODEL,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        temperature=0.8,
        max_tokens=1024,
    )

    text = response.choices[0].message.content
    start = text.find("{")
    end = text.rfind("}") + 1
    if start == -1 or end == 0:
        raise ValueError(f"No JSON in response: {text[:200]}")

    return json.loads(text[start:end])


def generate_image(image_prompt: str) -> bytes:
    """Stage 2: Generate image from prompt using gpt-image-1."""
    client = _get_openai_client()

    result = client.images.generate(
        model=IMAGE_MODEL,
        prompt=image_prompt,
        n=1,
        size="1024x1024",
        quality="medium",
    )

    image_b64 = result.data[0].b64_json
    if image_b64:
        return base64.b64decode(image_b64)

    # Fallback: download from URL if b64 not returned
    import httpx
    url = result.data[0].url
    resp = httpx.get(url)
    resp.raise_for_status()
    return resp.content


def validate_image(image_bytes: bytes, correct_answer: str) -> dict:
    """Stage 3: Validate image with GPT-4o-mini vision.

    Returns dict with: has_text (bool), quality_score (1-10), too_obvious (bool), feedback (str).
    """
    client = _get_openai_client()

    b64 = base64.b64encode(image_bytes).decode("utf-8")

    response = client.chat.completions.create(
        model=VALIDATION_MODEL,
        messages=[
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": f"""Analyze this image for a visual riddle quiz. The correct answer is "{correct_answer}".

Rate the image on these criteria and return a JSON object:

{{
  "has_text": false,  // Does the image contain ANY visible text, letters, words, or writing?
  "quality_score": 8, // Overall quality 1-10 (composition, style, visual appeal)
  "too_obvious": false, // Is the answer immediately obvious without thinking?
  "too_vague": false, // Are there too few clues to reasonably guess the answer?
  "feedback": "Brief explanation of your assessment"
}}

Return ONLY the JSON object.""",
                    },
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/png;base64,{b64}"},
                    },
                ],
            }
        ],
        temperature=0.3,
        max_tokens=512,
    )

    text = response.choices[0].message.content
    start = text.find("{")
    end = text.rfind("}") + 1
    return json.loads(text[start:end])


def generate_hint_image_with_validation(
    topic: str,
    correct_answer: str,
    difficulty: str,
    output_path: Optional[str | Path] = None,
) -> dict:
    """Full agentic pipeline: generate prompt → image → validate → retry.

    Args:
        topic: Question topic.
        correct_answer: The answer the image should hint at.
        difficulty: easy | medium | hard.
        output_path: If provided, save final image to this path.

    Returns:
        Dict with: question, image_prompt, image_bytes, validation, attempt_count.
    """
    # Stage 1: Generate question text + image prompt
    prompt_data = generate_hint_image_prompt(topic, correct_answer, difficulty)
    image_prompt = prompt_data["image_prompt"]

    for attempt in range(1, MAX_RETRIES + 1):
        print(f"  Attempt {attempt}/{MAX_RETRIES}: generating image...")

        # Stage 2: Generate image
        image_bytes = generate_image(image_prompt)

        # Stage 3: Validate
        validation = validate_image(image_bytes, correct_answer)
        print(f"  Validation: quality={validation.get('quality_score')}, "
              f"has_text={validation.get('has_text')}, "
              f"too_obvious={validation.get('too_obvious')}")

        # Check pass conditions
        has_text = validation.get("has_text", False)
        quality = validation.get("quality_score", 0)
        too_obvious = validation.get("too_obvious", False)

        if not has_text and quality >= 7 and not too_obvious:
            # Passed validation
            if output_path:
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(image_bytes)

            return {
                **prompt_data,
                "image_bytes": image_bytes,
                "validation": validation,
                "attempt_count": attempt,
            }

        # Stage 4: Modify prompt for retry
        feedback = validation.get("feedback", "")
        if has_text:
            image_prompt += " Absolutely no text, numbers, symbols, or writing of any kind."
        if too_obvious:
            image_prompt = image_prompt.replace("Oil painting", "Subtle oil painting")
            image_prompt += " Make the clues more abstract and metaphorical."
        if quality < 7:
            image_prompt += f" Improve quality: {feedback}"

        print(f"  Retrying with modified prompt...")

    # All retries failed — return last attempt with warning
    print(f"  WARNING: Image did not pass validation after {MAX_RETRIES} attempts")
    if output_path:
        output_path = Path(output_path)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_bytes(image_bytes)

    return {
        **prompt_data,
        "image_bytes": image_bytes,
        "validation": validation,
        "attempt_count": MAX_RETRIES,
        "validation_failed": True,
    }


def build_hint_image_question(
    topic: str,
    correct_answer: str,
    difficulty: str,
    media_url: str,
    pipeline_result: dict,
) -> dict:
    """Build a complete question dict from pipeline result."""
    generation_metadata = {
        "image_generator": IMAGE_MODEL,
        "image_prompt": pipeline_result.get("image_prompt", ""),
        "validation": pipeline_result.get("validation", {}),
        "attempt_count": pipeline_result.get("attempt_count", 0),
    }

    return {
        "question": pipeline_result["question"],
        "type": "image",
        "image_subtype": "hint_image",
        "correct_answer": correct_answer,
        "alternative_answers": pipeline_result.get("alternative_answers", []),
        "topic": topic,
        "category": "adults",
        "difficulty": difficulty,
        "tags": pipeline_result.get("tags", [topic.lower(), "hint-image"]),
        "language_dependent": False,
        "media_url": media_url,
        "explanation": pipeline_result.get("explanation"),
        "generation_metadata": generation_metadata,
    }
