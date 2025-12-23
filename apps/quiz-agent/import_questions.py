#!/usr/bin/env python3
"""Import questions to production via admin API.

This script reads questions from questions_export.json and imports them
to the production API using the admin endpoint.

Usage:
    # Import to production
    python import_questions.py --api-url https://quiz-agent-api.fly.dev --admin-key YOUR_KEY

    # Import to local (for testing)
    python import_questions.py --api-url http://localhost:8002 --admin-key YOUR_KEY

Environment variables:
    ADMIN_API_KEY: Admin API key (alternative to --admin-key)
"""

import sys
import os
import json
import requests
import argparse
from typing import List, Dict, Any

def import_questions(
    api_url: str,
    admin_key: str,
    questions_file: str = "questions_export.json",
    skip_duplicates: bool = True,
    force: bool = False,
    batch_size: int = 50
):
    """Import questions to API.

    Args:
        api_url: Base URL of API (e.g., https://quiz-agent-api.fly.dev)
        admin_key: Admin API key for authentication
        questions_file: Path to JSON file with questions
        skip_duplicates: Skip questions that already exist by ID
        force: Force import even if semantic duplicates detected
        batch_size: Number of questions per batch
    """
    # Load questions from file
    if not os.path.exists(questions_file):
        print(f"ERROR: Questions file not found: {questions_file}")
        print("Please run export_questions.py first to create the export file")
        sys.exit(1)

    with open(questions_file, "r", encoding="utf-8") as f:
        questions = json.load(f)

    print(f"Loaded {len(questions)} questions from {questions_file}")

    # Import in batches
    total_imported = 0
    total_skipped = 0
    total_failed = 0
    all_skipped_ids = []
    all_failed_ids = []

    # Remove trailing slash from API URL
    api_url = api_url.rstrip("/")
    endpoint = f"{api_url}/api/v1/admin/questions/import"

    for i in range(0, len(questions), batch_size):
        batch = questions[i:i+batch_size]
        batch_num = (i // batch_size) + 1
        total_batches = (len(questions) + batch_size - 1) // batch_size

        print(f"\nImporting batch {batch_num}/{total_batches} ({len(batch)} questions)...")

        # Prepare request
        headers = {
            "Content-Type": "application/json",
            "X-Admin-Key": admin_key
        }

        payload = {
            "questions": batch,
            "skip_duplicates": skip_duplicates,
            "force": force
        }

        try:
            response = requests.post(endpoint, json=payload, headers=headers, timeout=60)

            if response.status_code == 200:
                result = response.json()
                imported = result.get("imported_count", 0)
                skipped = result.get("skipped_count", 0)
                failed = result.get("failed_count", 0)

                total_imported += imported
                total_skipped += skipped
                total_failed += failed
                all_skipped_ids.extend(result.get("skipped_ids", []))
                all_failed_ids.extend(result.get("failed_ids", []))

                print(f"  ✓ Imported: {imported}, Skipped: {skipped}, Failed: {failed}")
            elif response.status_code == 401:
                print(f"  ✗ ERROR: Invalid admin API key")
                print(f"    Make sure ADMIN_API_KEY is set on the server")
                sys.exit(1)
            else:
                print(f"  ✗ ERROR: HTTP {response.status_code}")
                print(f"    Response: {response.text}")
                total_failed += len(batch)

        except requests.exceptions.Timeout:
            print(f"  ✗ ERROR: Request timeout")
            total_failed += len(batch)
        except requests.exceptions.ConnectionError as e:
            print(f"  ✗ ERROR: Connection failed: {e}")
            print(f"    Check that API is running at {api_url}")
            sys.exit(1)
        except Exception as e:
            print(f"  ✗ ERROR: {e}")
            total_failed += len(batch)

    # Summary
    print("\n" + "="*60)
    print("IMPORT SUMMARY")
    print("="*60)
    print(f"Total questions: {len(questions)}")
    print(f"Imported: {total_imported}")
    print(f"Skipped: {total_skipped}")
    print(f"Failed: {total_failed}")

    if all_skipped_ids:
        print(f"\nSkipped IDs ({len(all_skipped_ids)}):")
        for qid in all_skipped_ids[:10]:
            print(f"  - {qid}")
        if len(all_skipped_ids) > 10:
            print(f"  ... and {len(all_skipped_ids) - 10} more")

    if all_failed_ids:
        print(f"\nFailed IDs ({len(all_failed_ids)}):")
        for qid in all_failed_ids[:10]:
            print(f"  - {qid}")
        if len(all_failed_ids) > 10:
            print(f"  ... and {len(all_failed_ids) - 10} more")

    # Verify by checking stats
    print(f"\nVerifying import...")
    try:
        stats_response = requests.get(
            f"{api_url}/api/v1/admin/questions/stats",
            headers={"X-Admin-Key": admin_key},
            timeout=10
        )
        if stats_response.status_code == 200:
            stats = stats_response.json()
            print(f"✓ Database now has {stats['total_questions']} questions")
            print(f"  By difficulty: {stats['by_difficulty']}")
        else:
            print(f"✗ Could not verify: HTTP {stats_response.status_code}")
    except Exception as e:
        print(f"✗ Could not verify: {e}")

    print("\n✅ Import complete!")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Import questions to production API")
    parser.add_argument(
        "--api-url",
        default="https://quiz-agent-api.fly.dev",
        help="API base URL (default: production)"
    )
    parser.add_argument(
        "--admin-key",
        default=os.getenv("ADMIN_API_KEY"),
        help="Admin API key (or set ADMIN_API_KEY env var)"
    )
    parser.add_argument(
        "--questions-file",
        default="questions_export.json",
        help="Path to questions JSON file"
    )
    parser.add_argument(
        "--skip-duplicates",
        action="store_true",
        default=True,
        help="Skip questions that already exist by ID"
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Force import even if semantic duplicates detected"
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=50,
        help="Number of questions per batch (default: 50)"
    )

    args = parser.parse_args()

    if not args.admin_key:
        print("ERROR: Admin API key required")
        print("  Use --admin-key YOUR_KEY or set ADMIN_API_KEY environment variable")
        sys.exit(1)

    import_questions(
        api_url=args.api_url,
        admin_key=args.admin_key,
        questions_file=args.questions_file,
        skip_duplicates=args.skip_duplicates,
        force=args.force,
        batch_size=args.batch_size
    )
