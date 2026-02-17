#!/usr/bin/env python3
"""Update the gold-standard example library from approved high-rated questions in ChromaDB.

This script queries ChromaDB for approved questions with high ratings,
proposes candidates for the gold-standard library, and lets the user
manually confirm which ones to add.

Usage:
    python scripts/update_example_library.py
    python scripts/update_example_library.py --min-rating 4.0 --max-candidates 20
"""

import json
import os
import sys

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(PROJECT_ROOT, "packages", "shared"))
sys.path.insert(0, os.path.join(PROJECT_ROOT, "apps", "question-generator"))

from app.generation.storage import QuestionStorage


GOLD_STANDARD_PATH = os.path.join(PROJECT_ROOT, "data", "examples", "gold_standard.json")


def load_existing_gold_standard() -> list[dict]:
    """Load current gold-standard examples."""
    if os.path.exists(GOLD_STANDARD_PATH):
        with open(GOLD_STANDARD_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    return []


def save_gold_standard(examples: list[dict]) -> None:
    """Save gold-standard examples."""
    os.makedirs(os.path.dirname(GOLD_STANDARD_PATH), exist_ok=True)
    with open(GOLD_STANDARD_PATH, "w", encoding="utf-8") as f:
        json.dump(examples, f, indent=2, ensure_ascii=False)
    print(f"Saved {len(examples)} examples to {GOLD_STANDARD_PATH}")


def find_candidates(storage: QuestionStorage, min_rating: float = 4.0, max_candidates: int = 20) -> list:
    """Find approved questions with high ratings as gold-standard candidates."""
    all_questions = storage.get_all_questions()

    candidates = []
    for q in all_questions:
        if q.review_status != "approved":
            continue

        # Check quality ratings
        quality_score = q.calculate_quality_score()
        user_score = q.calculate_avg_rating()

        # Candidate if either quality score or user rating is high enough
        if (quality_score and quality_score >= min_rating) or (user_score and user_score >= min_rating):
            candidates.append({
                "question": q,
                "quality_score": quality_score,
                "user_score": user_score,
                "combined_score": (quality_score or 0) * 0.4 + (user_score or 0) * 0.6,
            })

    # Sort by combined score descending
    candidates.sort(key=lambda x: x["combined_score"], reverse=True)
    return candidates[:max_candidates]


def infer_pattern(question) -> str:
    """Attempt to infer the pattern from question metadata or tags."""
    meta = question.generation_metadata or {}
    reasoning = meta.get("reasoning", {})
    if isinstance(reasoning, dict):
        pattern = reasoning.get("pattern_used", "")
        if pattern:
            return pattern

    # Infer from tags
    tags = question.tags or []
    tag_to_pattern = {
        "number-sequence": "Number Sequence",
        "analogy": "Verbal Analogy",
        "odd-one-out": "Odd One Out",
        "lateral-thinking": "Lateral Thinking",
    }
    for tag, pattern in tag_to_pattern.items():
        if tag in tags:
            return pattern

    return "Unknown"


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Update gold-standard example library from ChromaDB")
    parser.add_argument("--min-rating", type=float, default=4.0, help="Minimum rating to consider (default: 4.0)")
    parser.add_argument("--max-candidates", type=int, default=20, help="Max candidates to propose (default: 20)")
    parser.add_argument("--auto", action="store_true", help="Skip interactive confirmation (add all candidates)")
    args = parser.parse_args()

    storage = QuestionStorage()
    existing = load_existing_gold_standard()
    existing_questions = {e["question"] for e in existing}

    print(f"Current gold-standard library: {len(existing)} examples")
    print(f"Searching for candidates (min rating: {args.min_rating})...\n")

    candidates = find_candidates(storage, args.min_rating, args.max_candidates)

    if not candidates:
        print("No candidates found matching criteria.")
        return

    print(f"Found {len(candidates)} candidates:\n")

    new_examples = []
    for i, c in enumerate(candidates, 1):
        q = c["question"]

        # Skip if already in library
        if q.question in existing_questions:
            continue

        print(f"--- Candidate {i}/{len(candidates)} ---")
        print(f"Q: {q.question}")
        print(f"A: {q.correct_answer}")
        print(f"Topic: {q.topic} | Difficulty: {q.difficulty}")
        print(f"Quality: {c['quality_score']:.1f} | User: {c['user_score']:.1f} | Combined: {c['combined_score']:.1f}")

        pattern = infer_pattern(q)
        print(f"Pattern: {pattern}")

        if args.auto:
            add = True
        else:
            response = input("\nAdd to gold-standard? [y/N/q(uit)] > ").strip().lower()
            if response == "q":
                break
            add = response == "y"

        if add:
            why_text = input("Why is this excellent? > ").strip() if not args.auto else f"High combined score ({c['combined_score']:.1f}). Approved in review."

            new_examples.append({
                "question": q.question,
                "answer": q.correct_answer if isinstance(q.correct_answer, str) else q.correct_answer[0],
                "why_excellent": why_text,
                "pattern": pattern,
                "source": q.source or "generated",
                "difficulty": q.difficulty,
                "topic": q.topic,
            })
        print()

    if new_examples:
        existing.extend(new_examples)
        save_gold_standard(existing)
        print(f"\nAdded {len(new_examples)} new examples to gold-standard library.")
    else:
        print("\nNo new examples added.")


if __name__ == "__main__":
    main()
