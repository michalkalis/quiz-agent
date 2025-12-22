#!/usr/bin/env python
"""Quick diagnostic script to check question database status."""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'packages/shared'))

from quiz_shared.database.chroma_client import ChromaDBClient

def main():
    print("=" * 60)
    print("Question Database Diagnostic")
    print("=" * 60)

    # Check main database
    print("\nChecking ./chroma_data database...")
    client = ChromaDBClient(persist_directory="./chroma_data")

    total = client.count_questions()
    print(f"✓ Total questions in database: {total}")

    if total == 0:
        print("\n⚠️  DATABASE IS EMPTY!")
        print("\nTo fix this, you need to:")
        print("1. Start the question-generator app:")
        print("   cd apps/question-generator")
        print("   python -m app.main")
        print("\n2. Open http://localhost:8001 in your browser")
        print("\n3. Either:")
        print("   - Generate new questions using the API")
        print("   - Import existing questions from a file")
        print("\n4. Review and approve questions in the web UI")
        return

    # Check review status distribution
    print("\nChecking review status...")
    try:
        all_questions = client.collection.get()
        statuses = {}
        difficulties = {}

        if all_questions and 'metadatas' in all_questions:
            for meta in all_questions['metadatas']:
                # Count review statuses
                status = meta.get('review_status', 'none')
                statuses[status] = statuses.get(status, 0) + 1

                # Count difficulties
                diff = meta.get('difficulty', 'unknown')
                difficulties[diff] = difficulties.get(diff, 0) + 1

            print(f"\nReview Status Distribution:")
            for status, count in sorted(statuses.items()):
                print(f"  {status:15}: {count}")

            print(f"\nDifficulty Distribution:")
            for diff, count in sorted(difficulties.items()):
                print(f"  {diff:15}: {count}")

            # Check for approved questions
            approved_count = statuses.get('approved', 0)
            if approved_count == 0:
                print("\n⚠️  NO APPROVED QUESTIONS FOUND!")
                print("\nThe quiz-agent requires approved questions to start a quiz.")
                print("\nTo fix this:")
                print("1. Go to http://localhost:8001 (question-generator web UI)")
                print("2. Review and approve questions")
                print("\nOR, for testing, you can approve all existing questions with:")
                print("   python approve_all_questions.py")
            else:
                print(f"\n✓ Found {approved_count} approved questions - quiz should work!")

    except Exception as e:
        print(f"\n❌ Error checking database: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    main()
