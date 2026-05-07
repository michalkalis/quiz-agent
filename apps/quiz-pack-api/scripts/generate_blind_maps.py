#!/usr/bin/env python3
"""End-to-end CLI for generating blind map questions.

Generates unlabeled map PNGs with red markers, uploads to R2,
generates verbal question text via LLM, and outputs question JSON.

Usage:
    # Dry run — generate images locally only
    python scripts/generate_blind_maps.py --count 5 --difficulty easy --dry-run

    # Generate all cities and upload to R2
    python scripts/generate_blind_maps.py --all

    # Generate specific cities
    python scripts/generate_blind_maps.py --cities "London,Tokyo,Belgrade"
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from app.image_generation.env_loader import load_env

load_env()

from openai import OpenAI

from app.image_generation.blind_maps import generate_blind_map, generate_labeled_map
from app.image_generation.city_dataset import CITIES, City

PROMPT_PATH = Path(__file__).parent.parent / "prompts" / "question_generation_map.md"


def generate_map_question_text(
    city: City,
    model: str = "gpt-4o",
) -> dict:
    """Generate verbal question text for a blind map question."""
    client = OpenAI()
    prompt_template = PROMPT_PATH.read_text()
    prompt = prompt_template.format(
        city_name=city.name,
        country_name=city.country,
        difficulty=city.difficulty,
    )
    response = client.chat.completions.create(
        model=model,
        max_tokens=1024,
        messages=[{"role": "user", "content": prompt}],
    )
    text = response.choices[0].message.content
    start = text.find("{")
    end = text.rfind("}") + 1
    if start == -1 or end == 0:
        raise ValueError(f"No JSON found in response: {text[:200]}")
    return json.loads(text[start:end])


def build_map_question(
    city: City,
    media_url: str,
    reveal_url: str | None = None,
    llm_data: dict | None = None,
    model: str = "gpt-4o",
) -> dict:
    """Build a complete question dict ready for import."""
    if llm_data is None:
        llm_data = generate_map_question_text(city, model)

    generation_metadata = {
        "image_generator": "cartopy_blind_map",
        "city": city.name,
        "country": city.country,
        "lat": city.lat,
        "lon": city.lon,
    }
    if reveal_url:
        generation_metadata["reveal_url"] = reveal_url

    return {
        "question": llm_data["question"],
        "type": "image",
        "image_subtype": "blind_map",
        "correct_answer": city.name,
        "alternative_answers": llm_data.get("alternative_answers", []),
        "topic": "Geography",
        "category": "adults",
        "difficulty": city.difficulty,
        "tags": llm_data.get("tags", ["geography", "cities", "blind-map"]),
        "language_dependent": False,
        "media_url": media_url,
        "explanation": llm_data.get("explanation"),
        "generation_metadata": generation_metadata,
    }


def main():
    parser = argparse.ArgumentParser(description="Generate blind map questions")
    parser.add_argument("--count", type=int, default=None)
    parser.add_argument("--difficulty", choices=["easy", "medium", "hard"], default=None)
    parser.add_argument("--cities", type=str, default=None, help="Comma-separated city names")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--output-dir", type=str, default="data/generated/blind_maps")
    parser.add_argument("--output-json", type=str, default=None)
    parser.add_argument("--model", type=str, default="gpt-4o")
    args = parser.parse_args()

    # Determine which cities to process
    if args.cities:
        city_names = {c.strip() for c in args.cities.split(",")}
        cities = [c for c in CITIES if c.name in city_names]
        if not cities:
            print("ERROR: No valid cities specified")
            sys.exit(1)
    else:
        cities = list(CITIES)

    if args.difficulty:
        cities = [c for c in cities if c.difficulty == args.difficulty]

    if args.count:
        cities = cities[: args.count]

    print(f"Generating blind maps for {len(cities)} cities...")

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    img_dir = output_dir / "images"
    img_dir.mkdir(exist_ok=True)

    questions = []

    for i, city in enumerate(cities, 1):
        slug = city.name.lower().replace(" ", "_")
        print(f"[{i}/{len(cities)}] {city.name}, {city.country} ({city.difficulty})...")

        # Generate blank map
        map_path = img_dir / f"{slug}.png"
        generate_blind_map(
            city.name, city.lat, city.lon,
            difficulty=city.difficulty,
            output_path=map_path,
        )
        print(f"  Map saved: {map_path}")

        # Generate labeled map (for reveal)
        labeled_path = img_dir / f"{slug}_labeled.png"
        generate_labeled_map(
            city.name, city.lat, city.lon,
            difficulty=city.difficulty,
            output_path=labeled_path,
        )
        print(f"  Labeled saved: {labeled_path}")

        if args.dry_run:
            questions.append({
                "city": city.name,
                "country": city.country,
                "difficulty": city.difficulty,
                "map_path": str(map_path),
                "labeled_path": str(labeled_path),
                "status": "dry_run",
            })
            continue

        # Upload to R2
        from app.image_generation.r2_uploader import upload_image

        media_url = upload_image(map_path, f"blind_maps/{slug}.png")
        reveal_url = upload_image(labeled_path, f"blind_maps/{slug}_labeled.png")
        print(f"  Uploaded: {media_url}")

        # Generate question text via LLM
        question_data = build_map_question(
            city, media_url, reveal_url, model=args.model,
        )
        questions.append(question_data)
        print(f"  Question: {question_data['question'][:80]}...")

    json_path = args.output_json or str(output_dir / "blind_map_questions.json")
    with open(json_path, "w") as f:
        json.dump(questions, f, indent=2, ensure_ascii=False)
    print(f"\nSaved {len(questions)} questions to {json_path}")


if __name__ == "__main__":
    main()
