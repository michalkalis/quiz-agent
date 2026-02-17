#!/usr/bin/env python3
"""Mark expired questions as 'expired' in ChromaDB.

Scans all questions for those past their expires_at date and updates
their review_status to "expired".

Usage:
    python scripts/expire_questions.py
    python scripts/expire_questions.py --dry-run
"""

import os
import sys
from datetime import datetime, timezone

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(PROJECT_ROOT, "packages", "shared"))
sys.path.insert(0, os.path.join(PROJECT_ROOT, "apps", "question-generator"))

from app.generation.storage import QuestionStorage


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Expire stale questions")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be expired without making changes")
    args = parser.parse_args()

    storage = QuestionStorage()
    all_questions = storage.get_all_questions()

    now = datetime.now(timezone.utc)
    expired_count = 0

    for q in all_questions:
        if q.review_status == "expired":
            continue  # already expired

        if q.expires_at is None:
            continue

        expires = q.expires_at
        if expires.tzinfo is None:
            expires = expires.replace(tzinfo=timezone.utc)

        if now > expires:
            expired_count += 1
            print(f"{'[DRY RUN] ' if args.dry_run else ''}Expiring: {q.question[:60]}...")
            print(f"  Expired at: {q.expires_at}")

            if not args.dry_run:
                storage.update_question_fields(q.id, {"review_status": "expired"})

    print(f"\nTotal expired: {expired_count}")
    if args.dry_run:
        print("(Dry run — no changes made)")


if __name__ == "__main__":
    main()
