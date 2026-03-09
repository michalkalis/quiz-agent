#!/usr/bin/env python3
"""End-to-end CLI for generating country silhouette questions.

Generates PNG silhouettes, uploads to R2, generates verbal question text via LLM,
and outputs question JSON ready for import.

Usage:
    # Generate 5 easy silhouettes (dry run — local only, no R2 upload)
    python scripts/generate_silhouettes.py --count 5 --difficulty easy --dry-run

    # Generate all silhouettes and upload to R2
    python scripts/generate_silhouettes.py --all

    # Generate specific countries
    python scripts/generate_silhouettes.py --countries "Italy,Japan,Chile"
"""

import argparse
import json
import sys
from pathlib import Path

# Add parent to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from app.image_generation.env_loader import load_env

load_env()

from app.image_generation.silhouettes import (
    SILHOUETTE_COUNTRIES,
    generate_labeled_silhouette,
    generate_silhouette,
)
from app.image_generation.silhouette_questions import build_silhouette_question


def main():
    parser = argparse.ArgumentParser(description="Generate country silhouette questions")
    parser.add_argument(
        "--count", type=int, default=None, help="Number of countries to process"
    )
    parser.add_argument(
        "--difficulty",
        choices=["easy", "medium", "hard"],
        default=None,
        help="Filter by difficulty",
    )
    parser.add_argument(
        "--countries", type=str, default=None, help="Comma-separated country names"
    )
    parser.add_argument("--all", action="store_true", help="Generate all countries")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Generate images locally without R2 upload or LLM calls",
    )
    parser.add_argument(
        "--output-dir",
        type=str,
        default="data/generated/silhouettes",
        help="Output directory for images and JSON",
    )
    parser.add_argument(
        "--output-json",
        type=str,
        default=None,
        help="Output JSON file path (default: <output-dir>/silhouette_questions.json)",
    )
    parser.add_argument(
        "--model",
        type=str,
        default="gpt-4o",
        help="OpenAI model for question text generation",
    )
    args = parser.parse_args()

    # Determine which countries to process
    if args.countries:
        country_names = [c.strip() for c in args.countries.split(",")]
        countries = []
        all_names = {c[0] for c in SILHOUETTE_COUNTRIES}
        for name in country_names:
            match = [(n, d, m) for n, d, m in SILHOUETTE_COUNTRIES if n == name]
            if match:
                countries.append(match[0])
            elif name in all_names:
                countries.append((name, "medium", False))
            else:
                print(f"WARNING: Country '{name}' not in SILHOUETTE_COUNTRIES, skipping")
        if not countries:
            print("ERROR: No valid countries specified")
            sys.exit(1)
    elif args.all:
        countries = list(SILHOUETTE_COUNTRIES)
    else:
        countries = list(SILHOUETTE_COUNTRIES)

    # Filter by difficulty
    if args.difficulty:
        countries = [(n, d, m) for n, d, m in countries if d == args.difficulty]

    # Limit count
    if args.count:
        countries = countries[: args.count]

    print(f"Generating silhouettes for {len(countries)} countries...")

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    img_dir = output_dir / "images"
    img_dir.mkdir(exist_ok=True)

    questions = []

    for i, (country_name, difficulty, metro_only) in enumerate(countries, 1):
        slug = country_name.lower().replace(" ", "_")
        print(f"[{i}/{len(countries)}] {country_name} ({difficulty})...")

        # Generate silhouette image
        silhouette_path = img_dir / f"{slug}.png"
        generate_silhouette(
            country_name,
            metropolitan_only=metro_only,
            output_path=silhouette_path,
        )
        print(f"  Silhouette saved: {silhouette_path}")

        # Generate labeled version (for reveal)
        labeled_path = img_dir / f"{slug}_labeled.png"
        generate_labeled_silhouette(
            country_name,
            metropolitan_only=metro_only,
            output_path=labeled_path,
        )
        print(f"  Labeled saved: {labeled_path}")

        if args.dry_run:
            # Skip R2 upload and LLM calls
            questions.append(
                {
                    "country": country_name,
                    "difficulty": difficulty,
                    "silhouette_path": str(silhouette_path),
                    "labeled_path": str(labeled_path),
                    "status": "dry_run",
                }
            )
            continue

        # Upload to R2
        from app.image_generation.r2_uploader import upload_image

        media_url = upload_image(silhouette_path, f"silhouettes/{slug}.png")
        reveal_url = upload_image(labeled_path, f"silhouettes/{slug}_labeled.png")
        print(f"  Uploaded: {media_url}")

        # Generate question text via LLM
        question_data = build_silhouette_question(
            country_name=country_name,
            difficulty=difficulty,
            media_url=media_url,
            reveal_url=reveal_url,
            model=args.model,
        )
        questions.append(question_data)
        print(f"  Question: {question_data['question'][:80]}...")

    # Save questions JSON
    json_path = args.output_json or str(output_dir / "silhouette_questions.json")
    with open(json_path, "w") as f:
        json.dump(questions, f, indent=2, ensure_ascii=False)
    print(f"\nSaved {len(questions)} questions to {json_path}")


if __name__ == "__main__":
    main()
