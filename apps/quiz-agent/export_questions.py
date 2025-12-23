#!/usr/bin/env python3
"""Export questions from local ChromaDB to JSON file.

This script exports all questions from the local database for import to production.
"""

import sys
import os
import json
from datetime import datetime

# Add shared package to path
sys.path.insert(0, '../../packages/shared')

from quiz_shared.database.chroma_client import ChromaDBClient

print("Exporting questions from local ChromaDB...")
print(f"Working directory: {os.getcwd()}")

# Use shared ChromaDB at project root
project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
chroma_path = os.path.join(project_root, "chroma_data")
print(f"ChromaDB directory: {chroma_path}")

# Check if directory exists
if not os.path.exists(chroma_path):
    print(f"ERROR: ChromaDB directory not found: {chroma_path}")
    print("Please populate the database first using populate_local_db.py")
    sys.exit(1)

# Initialize ChromaDB client
client = ChromaDBClient(
    collection_name="quiz_questions",
    persist_directory=chroma_path
)

# Get all questions
print("\nFetching all questions...")
questions = client.get_all_questions(limit=10000)

if not questions:
    print("No questions found in database!")
    sys.exit(1)

print(f"Found {len(questions)} questions")

# Convert to JSON-serializable format
questions_data = []
for q in questions:
    q_dict = {
        "id": q.id,
        "question": q.question,
        "type": q.type,
        "correct_answer": q.correct_answer,
        "alternative_answers": q.alternative_answers,
        "possible_answers": q.possible_answers,
        "topic": q.topic,
        "category": q.category,
        "difficulty": q.difficulty,
        "tags": q.tags,
        "source": q.source,
        "created_by": q.created_by,
        "media_url": q.media_url,
        "media_duration_seconds": q.media_duration_seconds,
        "explanation": q.explanation,
    }
    questions_data.append(q_dict)

# Save to JSON file
output_file = "questions_export.json"
with open(output_file, "w", encoding="utf-8") as f:
    json.dump(questions_data, f, indent=2, ensure_ascii=False)

print(f"\n✅ Exported {len(questions_data)} questions to {output_file}")

# Print statistics
by_difficulty = {}
by_topic = {}
for q in questions:
    by_difficulty[q.difficulty] = by_difficulty.get(q.difficulty, 0) + 1
    by_topic[q.topic] = by_topic.get(q.topic, 0) + 1

print("\nStatistics:")
print(f"  By difficulty:")
for diff, count in sorted(by_difficulty.items()):
    print(f"    - {diff}: {count}")
print(f"  By topic:")
for topic, count in sorted(by_topic.items()):
    print(f"    - {topic}: {count}")

print(f"\nNext step: Use import_questions.py to import to production")
