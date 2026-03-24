#!/usr/bin/env python3
"""Backup all ChromaDB questions to timestamped JSON file.

Usage:
    # Local backup (from apps/quiz-agent/)
    python scripts/backup_questions.py

    # Custom ChromaDB path
    python scripts/backup_questions.py --chroma-path /data/chroma_data

    # Custom output directory
    python scripts/backup_questions.py --output-dir ./my-backups

Backups are saved to data/backups/ by default with timestamped filenames.
"""

import argparse
import json
import logging
import os
import sys
from datetime import datetime
from pathlib import Path

# Add shared package to path (until sys.path hacks are removed)
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../..", "packages/shared"))

from quiz_shared.database.chroma_client import ChromaDBClient

logging.basicConfig(level=logging.INFO, format="%(message)s")
logger = logging.getLogger(__name__)


def backup_questions(chroma_path: str, output_dir: str) -> str | None:
    """Export all questions from ChromaDB to a timestamped JSON file.

    Args:
        chroma_path: Path to ChromaDB data directory
        output_dir: Directory to save backup files

    Returns:
        Path to the backup file, or None on failure
    """
    if not os.path.exists(chroma_path):
        logger.error("ChromaDB directory not found: %s", chroma_path)
        return None

    client = ChromaDBClient(
        collection_name="quiz_questions",
        persist_directory=chroma_path,
    )

    questions = client.get_all_questions(limit=10000)
    if not questions:
        logger.warning("No questions found in database")
        return None

    logger.info("Found %d questions", len(questions))

    # Serialize using Pydantic model_dump to capture ALL fields
    questions_data = []
    for q in questions:
        q_dict = q.model_dump(mode="json", exclude={"embedding"})
        questions_data.append(q_dict)

    # Create output directory
    os.makedirs(output_dir, exist_ok=True)

    # Timestamped filename
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_file = os.path.join(output_dir, f"questions_backup_{timestamp}.json")

    with open(output_file, "w", encoding="utf-8") as f:
        json.dump(
            {
                "exported_at": datetime.now().isoformat(),
                "count": len(questions_data),
                "questions": questions_data,
            },
            f,
            indent=2,
            ensure_ascii=False,
        )

    logger.info("Backed up %d questions to %s", len(questions_data), output_file)

    # Print stats
    by_status = {}
    by_difficulty = {}
    for q in questions:
        by_status[q.review_status] = by_status.get(q.review_status, 0) + 1
        by_difficulty[q.difficulty] = by_difficulty.get(q.difficulty, 0) + 1

    logger.info("\nBy review status:")
    for status, count in sorted(by_status.items()):
        logger.info("  %s: %d", status, count)
    logger.info("By difficulty:")
    for diff, count in sorted(by_difficulty.items()):
        logger.info("  %s: %d", diff, count)

    return output_file


def main():
    parser = argparse.ArgumentParser(description="Backup ChromaDB questions to JSON")
    parser.add_argument(
        "--chroma-path",
        default=None,
        help="Path to ChromaDB data directory (default: auto-detect)",
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help="Output directory for backups (default: data/backups/)",
    )
    args = parser.parse_args()

    # Auto-detect paths relative to project root
    project_root = Path(__file__).resolve().parent.parent.parent.parent
    chroma_path = args.chroma_path or str(project_root / "chroma_data")
    output_dir = args.output_dir or str(project_root / "data" / "backups")

    result = backup_questions(chroma_path, output_dir)
    if not result:
        sys.exit(1)


if __name__ == "__main__":
    main()
