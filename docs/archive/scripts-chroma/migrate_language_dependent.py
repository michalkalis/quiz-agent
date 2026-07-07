"""Classify existing questions as language-dependent using GPT-4o-mini.

This script:
1. Loads all questions from ChromaDB
2. Batch-classifies each with GPT-4o-mini (is this question language-dependent?)
3. Updates metadata in ChromaDB
4. Reports summary statistics

A question is "language-dependent" if it relies on English language properties:
- Wordplay, puns, anagrams that only work in English
- Answers that depend on English spelling or letter counts
- English-specific acronyms as the core of the question

Usage:
    # Dry run (review classifications without updating DB)
    python scripts/migrate_language_dependent.py --dry-run

    # Apply changes
    python scripts/migrate_language_dependent.py

    # Custom ChromaDB path
    python scripts/migrate_language_dependent.py --chroma-path ./chroma_data
"""

import argparse
import json
import os
import sys
from pathlib import Path

from openai import OpenAI

# Add shared package to path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "packages" / "shared"))
from quiz_shared.database.chroma_client import ChromaDBClient


BATCH_SIZE = 20
MODEL = "gpt-4o-mini"

CLASSIFICATION_PROMPT = """You are classifying pub quiz questions for language dependency.

A question is "language_dependent: true" if its answer or core mechanism relies on English language properties:
- Answer depends on English spelling, letter counts, or word structure
- Wordplay, puns, or anagrams that only work in English
- English-specific acronyms or abbreviations as the core of the question
- Rhymes or phonetic tricks specific to English

A question is "language_dependent: false" if:
- The answer is a factual thing (person, place, number, object) that works in any language
- The question is about universal knowledge (science, geography, history, nature)
- Even if the question mentions English words, the ANSWER itself is language-agnostic

Classify each question below. Return a JSON array of booleans in the same order.

Questions:
{questions_json}

Return ONLY a JSON array of booleans, e.g. [false, false, true, false]
"""


def classify_batch(client: OpenAI, questions: list[dict]) -> list[bool]:
    """Classify a batch of questions using GPT-4o-mini.

    Args:
        client: OpenAI client
        questions: List of {"id": ..., "question": ..., "correct_answer": ...}

    Returns:
        List of booleans (True = language-dependent)
    """
    questions_json = json.dumps(
        [{"question": q["question"], "answer": q["correct_answer"]} for q in questions],
        indent=2,
    )

    response = client.chat.completions.create(
        model=MODEL,
        temperature=0.0,
        messages=[
            {
                "role": "user",
                "content": CLASSIFICATION_PROMPT.format(questions_json=questions_json),
            }
        ],
    )

    content = response.choices[0].message.content.strip()

    # Parse JSON array from response
    start = content.find("[")
    end = content.rfind("]") + 1
    if start == -1 or end <= start:
        print(f"  WARNING: Could not parse response: {content[:200]}")
        return [False] * len(questions)

    try:
        results = json.loads(content[start:end])
        if len(results) != len(questions):
            print(f"  WARNING: Expected {len(questions)} results, got {len(results)}")
            # Pad or truncate
            results = (results + [False] * len(questions))[:len(questions)]
        return results
    except json.JSONDecodeError as e:
        print(f"  WARNING: JSON parse error: {e}")
        return [False] * len(questions)


def main():
    parser = argparse.ArgumentParser(description="Classify questions as language-dependent")
    parser.add_argument(
        "--chroma-path",
        default="./chroma_data",
        help="Path to ChromaDB data directory (default: ./chroma_data)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview classifications without updating the database",
    )
    args = parser.parse_args()

    # Verify OpenAI API key
    if not os.environ.get("OPENAI_API_KEY"):
        print("ERROR: OPENAI_API_KEY environment variable not set")
        sys.exit(1)

    # Connect to ChromaDB
    print(f"Connecting to ChromaDB at: {args.chroma_path}")
    chroma = ChromaDBClient(persist_directory=args.chroma_path)

    # Load all questions
    questions = chroma.get_all_questions(limit=5000)
    print(f"Loaded {len(questions)} questions")

    if not questions:
        print("No questions found. Nothing to do.")
        return

    # Prepare for classification
    openai_client = OpenAI()
    total_flagged = 0
    total_processed = 0
    flagged_questions = []

    # Process in batches
    for i in range(0, len(questions), BATCH_SIZE):
        batch = questions[i : i + BATCH_SIZE]
        batch_data = [
            {"id": q.id, "question": q.question, "correct_answer": q.correct_answer}
            for q in batch
        ]

        print(f"\nBatch {i // BATCH_SIZE + 1}/{(len(questions) + BATCH_SIZE - 1) // BATCH_SIZE} ({len(batch)} questions)...")
        results = classify_batch(openai_client, batch_data)

        for q, is_lang_dep in zip(batch, results):
            total_processed += 1
            if is_lang_dep:
                total_flagged += 1
                flagged_questions.append(
                    {"id": q.id, "question": q.question, "answer": q.correct_answer}
                )
                print(f"  FLAGGED: {q.question[:80]}... → {q.correct_answer}")

                if not args.dry_run:
                    q.language_dependent = True
                    chroma.update_question_obj(q)

    # Summary
    print(f"\n{'='*60}")
    print(f"Migration Summary {'(DRY RUN)' if args.dry_run else ''}")
    print(f"{'='*60}")
    print(f"Total questions: {len(questions)}")
    print(f"Processed: {total_processed}")
    print(f"Flagged as language-dependent: {total_flagged} ({total_flagged / len(questions) * 100:.1f}%)")

    if flagged_questions:
        print(f"\nFlagged questions:")
        for fq in flagged_questions:
            print(f"  - [{fq['id']}] {fq['question'][:70]}... → {fq['answer']}")

    if args.dry_run:
        print(f"\nThis was a dry run. Run without --dry-run to apply changes.")
    else:
        print(f"\nDatabase updated successfully.")


if __name__ == "__main__":
    main()
