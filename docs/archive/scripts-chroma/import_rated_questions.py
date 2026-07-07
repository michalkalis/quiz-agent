"""Import existing rated questions from pub-quiz-finetuning project."""

import json
import sys
import os
from datetime import datetime

# Add shared package to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "packages/shared"))

from quiz_shared.models.question import Question
from quiz_shared.database.chroma_client import ChromaDBClient


def import_questions_from_file(file_path: str, reviewer_id: str = "michal"):
    """Import questions from JSON file.

    Args:
        file_path: Path to JSON file with questions
        reviewer_id: Reviewer user ID
    """
    print(f"Loading questions from: {file_path}")

    with open(file_path, 'r') as f:
        questions_data = json.load(f)

    print(f"Found {len(questions_data)} questions")

    # Initialize ChromaDB
    chroma = ChromaDBClient()

    imported = 0
    skipped = 0

    for q_data in questions_data:
        try:
            # Convert rating (1-5) to quality_ratings
            rating = q_data.get("rating", 3)
            quality_ratings = {
                "surprise_factor": rating,
                "clarity": rating,
                "universal_appeal": rating,
                "creativity": rating
            }

            # Create Question object
            question = Question(
                id=f"q_imported_{os.urandom(6).hex()}",
                question=q_data.get("question", ""),
                type="text",
                correct_answer=q_data.get("answer", ""),
                possible_answers=None,
                alternative_answers=[],
                topic=_map_category_to_topic(q_data.get("category", "general")),
                category="adults",  # Default category
                difficulty=q_data.get("difficulty", "medium"),
                tags=[],
                source=q_data.get("source", "imported"),
                review_status="approved",  # Mark as approved
                reviewed_by=reviewer_id,
                reviewed_at=datetime.now(),
                review_notes=f"Imported from {file_path} with rating {rating}/5",
                quality_ratings=quality_ratings
            )

            # Check for duplicates
            duplicates = chroma.find_duplicates(question.question, threshold=0.90)

            if duplicates:
                print(f"Skipping duplicate: {question.question[:50]}...")
                skipped += 1
                continue

            # Add to database
            success = chroma.add_question(question)

            if success:
                imported += 1
                print(f"Imported ({imported}): {question.question[:60]}...")
            else:
                print(f"Failed to import: {question.question[:50]}...")
                skipped += 1

        except Exception as e:
            print(f"Error importing question: {e}")
            skipped += 1
            continue

    print(f"\nImport complete!")
    print(f"  Imported: {imported}")
    print(f"  Skipped: {skipped}")
    print(f"  Total: {len(questions_data)}")


def _map_category_to_topic(category: str) -> str:
    """Map category to topic.

    Args:
        category: Category from source file

    Returns:
        Mapped topic
    """
    mapping = {
        "literature": "Literature",
        "general_knowledge": "General Knowledge",
        "entertainment": "Entertainment",
        "science": "Science",
        "history": "History",
        "geography": "Geography",
        "sports": "Sports",
        "music": "Music",
        "art": "Arts",
        "film": "Film & TV",
        "food": "Food & Drink",
    }

    return mapping.get(category.lower(), "General Knowledge")


if __name__ == "__main__":
    # Default path to high quality questions
    default_path = os.path.expanduser(
        "~/Library/CloudStorage/GoogleDrive-michal.kalis@gmail.com/My Drive/_projects/ai-developer-course/code/pub-quiz-finetuning/data/dpo_training/high_quality.json"
    )

    if len(sys.argv) > 1:
        file_path = sys.argv[1]
    else:
        file_path = default_path

    if not os.path.exists(file_path):
        print(f"Error: File not found: {file_path}")
        print(f"\nUsage: python {sys.argv[0]} <path_to_questions.json>")
        sys.exit(1)

    import_questions_from_file(file_path)
