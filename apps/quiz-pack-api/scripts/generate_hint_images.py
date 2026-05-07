#!/usr/bin/env python3
"""End-to-end CLI for generating AI hint image questions.

Uses the agentic pipeline: LLM prompt → image generation → vision validation → retry.

Usage:
    # Generate a single hint image
    python scripts/generate_hint_images.py --topic "Literature" --answer "The Great Gatsby" --difficulty easy

    # Generate from a batch file
    python scripts/generate_hint_images.py --batch-file data/hint_image_seeds.json

    # Dry run (generate prompts only, no image generation)
    python scripts/generate_hint_images.py --topic "Science" --answer "DNA" --difficulty medium --dry-run
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from app.image_generation.env_loader import load_env

load_env()

from app.image_generation.hint_images import (
    build_hint_image_question,
    generate_hint_image_prompt,
    generate_hint_image_with_validation,
)


def main():
    parser = argparse.ArgumentParser(description="Generate AI hint image questions")
    parser.add_argument("--topic", type=str, help="Question topic")
    parser.add_argument("--answer", type=str, help="Correct answer")
    parser.add_argument("--difficulty", choices=["easy", "medium", "hard"], default="medium")
    parser.add_argument(
        "--batch-file",
        type=str,
        help='JSON file with array of {topic, correct_answer, difficulty}',
    )
    parser.add_argument("--dry-run", action="store_true", help="Generate prompts only")
    parser.add_argument("--output-dir", type=str, default="data/generated/hint_images")
    parser.add_argument("--output-json", type=str, default=None)
    args = parser.parse_args()

    # Build list of items to generate
    items = []
    if args.batch_file:
        with open(args.batch_file) as f:
            items = json.load(f)
    elif args.topic and args.answer:
        items = [
            {"topic": args.topic, "correct_answer": args.answer, "difficulty": args.difficulty}
        ]
    else:
        print("ERROR: Provide --topic + --answer, or --batch-file")
        sys.exit(1)

    print(f"Generating {len(items)} hint image questions...")

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    img_dir = output_dir / "images"
    img_dir.mkdir(exist_ok=True)

    questions = []

    for i, item in enumerate(items, 1):
        topic = item["topic"]
        answer = item["correct_answer"]
        difficulty = item.get("difficulty", "medium")
        slug = answer.lower().replace(" ", "_").replace("'", "")[:40]

        print(f"\n[{i}/{len(items)}] {topic}: {answer} ({difficulty})")

        if args.dry_run:
            prompt_data = generate_hint_image_prompt(topic, answer, difficulty)
            questions.append({
                "topic": topic,
                "correct_answer": answer,
                "difficulty": difficulty,
                "question": prompt_data["question"],
                "image_prompt": prompt_data["image_prompt"],
                "status": "dry_run",
            })
            print(f"  Prompt: {prompt_data['image_prompt'][:80]}...")
            continue

        # Run full agentic pipeline
        image_path = img_dir / f"{slug}.png"
        result = generate_hint_image_with_validation(
            topic, answer, difficulty, output_path=image_path,
        )

        # Upload to R2
        from app.image_generation.r2_uploader import upload_image

        media_url = upload_image(image_path, f"hint_images/{slug}.png")
        print(f"  Uploaded: {media_url}")

        question_data = build_hint_image_question(
            topic, answer, difficulty, media_url, result,
        )
        questions.append(question_data)

        if result.get("validation_failed"):
            print(f"  WARNING: Image did not pass validation")
        print(f"  Question: {question_data['question'][:80]}...")

    json_path = args.output_json or str(output_dir / "hint_image_questions.json")
    with open(json_path, "w") as f:
        json.dump(questions, f, indent=2, ensure_ascii=False)
    print(f"\nSaved {len(questions)} questions to {json_path}")


if __name__ == "__main__":
    main()
