#!/usr/bin/env python
"""Remove questions flagged as incorrect or needs_fix by the verification report.

Usage:
    python scripts/remove_invalid_questions.py
"""

import json
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'packages', 'shared'))

from quiz_shared.database.chroma_client import ChromaDBClient

REPORT_PATH = os.path.join(
    os.path.dirname(__file__), '..', 'data', 'verification', 'report_2026-02-09.json'
)
CHROMA_DIR = os.path.join(os.path.dirname(__file__), '..', 'chroma_data')

REMOVAL_VERDICTS = {"incorrect", "needs_fix"}


def load_flagged_questions() -> list[dict]:
    """Load questions flagged for removal from the verification report."""
    with open(REPORT_PATH) as f:
        report = json.load(f)
    return [q for q in report["questions"] if q["verdict"] in REMOVAL_VERDICTS]


def remove_questions(questions: list[dict]) -> None:
    """Hard-delete flagged questions from ChromaDB.

    Audit trail preserved in data/verification/report_2026-02-09.json.
    """
    client = ChromaDBClient(persist_directory=CHROMA_DIR)

    print(f"Found {len(questions)} questions to remove:\n")
    for q in questions:
        print(f"  [{q['verdict']:10}] {q['id']}")
        print(f"             {q['question'][:80]}")
    print()

    removed, failed = 0, 0
    for q in questions:
        if client.delete_question(q["id"]):
            print(f"  Deleted {q['id']}")
            removed += 1
        else:
            print(f"  FAILED  {q['id']}")
            failed += 1

    print(f"\nDone: {removed} deleted, {failed} failed.")


if __name__ == "__main__":
    flagged = load_flagged_questions()
    if not flagged:
        print("No questions flagged for removal.")
        sys.exit(0)
    remove_questions(flagged)
