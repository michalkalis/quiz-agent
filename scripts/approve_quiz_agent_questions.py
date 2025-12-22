#!/usr/bin/env python
"""Approve all questions in quiz-agent database for testing."""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'packages/shared'))

from quiz_shared.database.chroma_client import ChromaDBClient

def main():
    print("=" * 60)
    print("Approving Quiz-Agent Database Questions")
    print("=" * 60)

    db_path = "./apps/quiz-agent/data/chromadb"
    client = ChromaDBClient(persist_directory=db_path)

    # Get all questions
    all_questions = client.collection.get()

    if not all_questions or not all_questions['ids']:
        print("\n⚠️  No questions found in database!")
        return

    total = len(all_questions['ids'])
    print(f"\nFound {total} questions")

    # Update review status to 'approved' for all questions
    print("\nApproving questions...")

    updated_metadatas = []
    for metadata in all_questions['metadatas']:
        # Create a copy and update review_status
        updated_meta = metadata.copy()
        updated_meta['review_status'] = 'approved'
        updated_metadatas.append(updated_meta)

    # Update all questions at once
    client.collection.update(
        ids=all_questions['ids'],
        metadatas=updated_metadatas
    )

    print(f"✓ Approved all {total} questions!")

    # Verify
    updated_questions = client.collection.get()
    approved_count = sum(1 for meta in updated_questions['metadatas']
                        if meta.get('review_status') == 'approved')

    print(f"\nVerification:")
    print(f"  Total questions: {len(updated_questions['ids'])}")
    print(f"  Approved: {approved_count}")

    if approved_count == total:
        print("\n✓ SUCCESS! You can now start a quiz.")
    else:
        print(f"\n⚠️  Warning: Only {approved_count}/{total} questions are approved")

if __name__ == "__main__":
    main()
