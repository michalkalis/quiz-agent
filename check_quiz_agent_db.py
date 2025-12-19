#!/usr/bin/env python
"""Check quiz-agent's specific database."""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'packages/shared'))

from quiz_shared.database.chroma_client import ChromaDBClient

def main():
    print("=" * 60)
    print("Quiz-Agent Database Status")
    print("=" * 60)

    # Check quiz-agent's database
    db_path = "./apps/quiz-agent/data/chromadb"
    print(f"\nDatabase path: {db_path}")

    if not os.path.exists(db_path):
        print("\n⚠️  Database doesn't exist yet!")
        print("\nThis is normal for a first run. The database will be created")
        print("when you add questions to it.")
        return

    client = ChromaDBClient(persist_directory=db_path)
    total = client.count_questions()
    print(f"Total questions: {total}")

    if total == 0:
        print("\n⚠️  Database is empty!")
        return

    # Check review status and other metadata
    all_questions = client.collection.get()
    statuses = {}
    difficulties = {}
    categories = {}
    types = {}

    if all_questions and 'metadatas' in all_questions:
        for meta in all_questions['metadatas']:
            # Count review statuses
            status = meta.get('review_status', 'none')
            statuses[status] = statuses.get(status, 0) + 1

            # Count difficulties
            diff = meta.get('difficulty', 'unknown')
            difficulties[diff] = difficulties.get(diff, 0) + 1

            # Count categories
            cat = meta.get('category', 'none')
            categories[cat] = categories.get(cat, 0) + 1

            # Count types
            qtype = meta.get('type', 'unknown')
            types[qtype] = types.get(qtype, 0) + 1

        print(f"\nReview Status:")
        for status, count in sorted(statuses.items()):
            emoji = "✓" if status == "approved" else "⚠️"
            print(f"  {emoji} {status:15}: {count}")

        print(f"\nDifficulty:")
        for diff, count in sorted(difficulties.items()):
            print(f"  {diff:15}: {count}")

        print(f"\nCategory:")
        for cat, count in sorted(categories.items()):
            print(f"  {cat:15}: {count}")

        print(f"\nType:")
        for qtype, count in sorted(types.items()):
            print(f"  {qtype:15}: {count}")

        # Check if quiz can start
        approved_count = statuses.get('approved', 0)
        approved_text = sum(1 for i, meta in enumerate(all_questions['metadatas'])
                          if meta.get('review_status') == 'approved'
                          and meta.get('type') == 'text'
                          and meta.get('category') != 'children')

        print(f"\n" + "=" * 60)
        print(f"Quiz Requirements Check:")
        print(f"  Approved + text + not 'children': {approved_text}")

        if approved_text == 0:
            print(f"\n❌ Cannot start quiz - no questions meet requirements!")
            print(f"\nRequirements:")
            print(f"  - review_status: approved")
            print(f"  - type: text")
            print(f"  - category: NOT 'children'")
        else:
            print(f"\n✓ Can start quiz!")

if __name__ == "__main__":
    main()
