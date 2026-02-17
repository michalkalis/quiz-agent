#!/usr/bin/env python3
"""Generation worker — processes pending generation requests.

Reads from data/generation_queue/pending.json, runs the question generation
pipeline, imports results to ChromaDB as pending_review.

Usage:
    python scripts/generation_worker.py
    python scripts/generation_worker.py --dry-run
"""

import json
import os
import sys
from datetime import datetime, timezone

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(PROJECT_ROOT, "packages", "shared"))
sys.path.insert(0, os.path.join(PROJECT_ROOT, "apps", "question-generator"))

QUEUE_DIR = os.path.join(PROJECT_ROOT, "data", "generation_queue")
PENDING_FILE = os.path.join(QUEUE_DIR, "pending.json")
COMPLETED_FILE = os.path.join(QUEUE_DIR, "completed.json")


def load_queue() -> list[dict]:
    """Load pending generation requests."""
    if not os.path.exists(PENDING_FILE):
        return []
    with open(PENDING_FILE, "r", encoding="utf-8") as f:
        return json.load(f)


def save_queue(items: list[dict]) -> None:
    """Save pending queue."""
    os.makedirs(QUEUE_DIR, exist_ok=True)
    with open(PENDING_FILE, "w", encoding="utf-8") as f:
        json.dump(items, f, indent=2)


def append_completed(item: dict) -> None:
    """Append a completed item to the completed log."""
    os.makedirs(QUEUE_DIR, exist_ok=True)
    completed = []
    if os.path.exists(COMPLETED_FILE):
        with open(COMPLETED_FILE, "r", encoding="utf-8") as f:
            completed = json.load(f)
    completed.append(item)
    with open(COMPLETED_FILE, "w", encoding="utf-8") as f:
        json.dump(completed, f, indent=2)


def process_request(request: dict, dry_run: bool = False) -> dict:
    """Process a single generation request.

    Returns completed request with results.
    """
    count = request.get("count", 10)
    difficulty = request.get("difficulty", "medium")
    topics = request.get("topics")
    reason = request.get("reason", "manual")

    print(f"Processing: {count} {difficulty} questions (reason: {reason})")

    if dry_run:
        print("  [DRY RUN] Skipping actual generation")
        request["status"] = "dry_run"
        request["completed_at"] = datetime.now(timezone.utc).isoformat()
        return request

    # Import generation pipeline
    try:
        from app.generation.storage import QuestionStorage
        from app.generation.advanced_generator import AdvancedQuestionGenerator
        import asyncio

        generator = AdvancedQuestionGenerator(
            generation_model="gpt-4o",
            critique_model="gpt-4o-mini",
        )

        questions = asyncio.run(generator.generate_questions(
            count=count,
            difficulty=difficulty,
            topics=topics,
            enable_best_of_n=True,
            n_multiplier=2,
            min_quality_score=6.0,
        ))

        # Import to ChromaDB as pending_review
        storage = QuestionStorage()
        approved, failed = storage.bulk_approve(questions)

        request["status"] = "completed"
        request["questions_generated"] = len(questions)
        request["questions_imported"] = len(approved)
        request["questions_failed"] = len(failed)
        request["completed_at"] = datetime.now(timezone.utc).isoformat()

        print(f"  Generated: {len(questions)}, Imported: {len(approved)}, Failed: {len(failed)}")

    except Exception as e:
        print(f"  ERROR: {e}")
        request["status"] = "error"
        request["error"] = str(e)
        request["completed_at"] = datetime.now(timezone.utc).isoformat()

    return request


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Process pending generation queue")
    parser.add_argument("--dry-run", action="store_true", help="Don't actually generate, just show what would happen")
    args = parser.parse_args()

    queue = load_queue()

    if not queue:
        print("No pending generation requests.")
        return

    print(f"Found {len(queue)} pending request(s)\n")

    remaining = []
    for request in queue:
        result = process_request(request, dry_run=args.dry_run)
        if result.get("status") in ("completed", "error", "dry_run"):
            append_completed(result)
        else:
            remaining.append(result)

    save_queue(remaining)
    print(f"\nDone. Remaining in queue: {len(remaining)}")


if __name__ == "__main__":
    main()
