#!/usr/bin/env python3
"""Apply corrected questions to production by deleting old versions and re-importing.

Requires the admin list endpoint (GET /api/v1/admin/questions?search=...).

Usage:
    # Dry run (default)
    python scripts/apply_corrections_production.py --dry-run

    # Apply to production
    python scripts/apply_corrections_production.py
"""

import json
import os
import sys
import requests
from pathlib import Path

API_URL = os.getenv("QUIZ_API_URL", "https://quiz-agent-api.fly.dev")
ADMIN_KEY = os.getenv("ADMIN_API_KEY")


def load_questions(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    return data if isinstance(data, list) else data.get("questions", [])


def find_question(search_term):
    """Search production for a question by text substring."""
    resp = requests.get(
        f"{API_URL}/api/v1/admin/questions",
        params={"search": search_term},
        headers={"X-Admin-Key": ADMIN_KEY},
        timeout=15,
    )
    resp.raise_for_status()
    results = resp.json()["questions"]
    return results


def delete_question(question_id):
    resp = requests.delete(
        f"{API_URL}/api/v1/admin/questions/{question_id}",
        headers={"X-Admin-Key": ADMIN_KEY},
        timeout=15,
    )
    resp.raise_for_status()
    return resp.json()


def import_questions(questions):
    """Import questions with force (skip semantic duplicate check)."""
    resp = requests.post(
        f"{API_URL}/api/v1/admin/questions/import",
        json={"questions": questions, "skip_duplicates": False, "force": True},
        headers={"X-Admin-Key": ADMIN_KEY, "Content-Type": "application/json"},
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()


# Each correction: (search_term_for_old_question, batch_file, search_term_for_new_question)
CORRECTIONS = [
    ("frog survives winter", "data/generated/claude_batch_005.json", "ice crystals forming between"),
    ("underground fungal", "data/generated/claude_batch_005.json", "underground fungal networks"),
    ("Fencing, athletics, swimming", "data/generated/claude_batch_013.json", "Horse riding was replaced"),
    ("first iPhone launched in 2007", "data/generated/claude_batch_013.json", "two years later, in 2009"),
    ("longest goal scored by a goalkeeper", "data/generated/claude_batch_013.json", "Guinness World Record for the longest goal"),
    ("SpaceX lands its rocket", "data/generated/claude_batch_013.json", "Including prototype test vehicles"),
    ("Apollo 11 moon landing guidance", "data/generated/claude_batch_013.json", "A modern smartphone app like Instagram"),
    ("gold medals in both the Summer and Winter", "data/generated/claude_batch_013.json", "Eddie Eagan"),
    ("Victor Hugo", "data/generated/claude_batch_016.json", "famous literary anecdote"),
]


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if not ADMIN_KEY:
        print("ERROR: Set ADMIN_API_KEY environment variable")
        sys.exit(1)

    # Pre-load batch files
    batch_cache = {}
    for _, bfile, _ in CORRECTIONS:
        if bfile not in batch_cache:
            batch_cache[bfile] = load_questions(bfile)

    deleted = 0
    imported = 0
    errors = 0

    for search_old, bfile, search_new in CORRECTIONS:
        # Find old question on production
        matches = find_question(search_old)
        if not matches:
            print(f"  NOT FOUND on production: '{search_old}'")
            errors += 1
            continue

        if len(matches) > 1:
            print(f"  AMBIGUOUS ({len(matches)} matches): '{search_old}'")
            for m in matches:
                print(f"    {m['id']}: {m['question'][:70]}")
            errors += 1
            continue

        old = matches[0]
        old_id = old["id"]

        # Find corrected version in batch file
        new_q = None
        for q in batch_cache[bfile]:
            if search_new in q["question"]:
                new_q = q
                break

        if not new_q:
            print(f"  CORRECTION NOT FOUND in {bfile}: '{search_new}'")
            errors += 1
            continue

        print(f"  {old_id}: '{old['question'][:60]}...'")
        print(f"    Old answer: {old['correct_answer']}")
        print(f"    New answer: {new_q['correct_answer']}")

        if args.dry_run:
            print(f"    [DRY RUN] Would delete {old_id} and re-import")
            deleted += 1
            imported += 1
            continue

        # Delete old
        delete_question(old_id)
        deleted += 1
        print(f"    Deleted {old_id}")

        # Re-import with same ID
        import_q = dict(new_q)
        import_q["id"] = old_id
        result = import_questions([import_q])
        if result.get("imported_count", 0) == 1:
            imported += 1
            print(f"    Re-imported {old_id}")
        else:
            print(f"    IMPORT FAILED: {result}")
            errors += 1

    print(f"\n{'='*50}")
    print(f"{'DRY RUN ' if args.dry_run else ''}Summary")
    print(f"{'='*50}")
    print(f"Deleted:  {deleted}")
    print(f"Imported: {imported}")
    print(f"Errors:   {errors}")

    # Show final stats
    if not args.dry_run:
        resp = requests.get(
            f"{API_URL}/api/v1/admin/questions/stats",
            headers={"X-Admin-Key": ADMIN_KEY},
            timeout=10,
        )
        if resp.ok:
            stats = resp.json()
            print(f"\nProduction: {stats['total_questions']} total questions")


if __name__ == "__main__":
    main()
