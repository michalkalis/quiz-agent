#!/usr/bin/env python3
"""Test ChromaDB queries directly to isolate the issue."""

import sys
import os

# Load .env from project root
from dotenv import load_dotenv
load_dotenv('../../.env')

# Add shared package to path
sys.path.insert(0, '../../packages/shared')

from quiz_shared.database.chroma_client import ChromaDBClient

print("=== Testing ChromaDB Queries ===\n")

# Initialize client
client = ChromaDBClient(
    collection_name="quiz_questions",
    persist_directory="./data/chromadb"
)

# Test 1: Count all questions
print("Test 1: Count all questions")
total = client.count_questions()
print(f"Total questions: {total}\n")

# Test 2: Get all questions without filters
print("Test 2: Get all questions (no filters)")
try:
    results = client.collection.get()
    print(f"✓ Got {len(results['ids'])} questions")
    print(f"  First question: {results['documents'][0][:60]}...\n")
except Exception as e:
    print(f"✗ Error: {e}\n")

# Test 3: Get with limit parameter
print("Test 3: Get with limit=5")
try:
    results = client.collection.get(limit=5)
    print(f"✓ Got {len(results['ids'])} questions\n")
except Exception as e:
    print(f"✗ Error: {e}\n")

# Test 4: Simple where clause (single condition)
print("Test 4: Simple where clause - type=text")
try:
    results = client.collection.get(
        where={"type": "text"},
        limit=5
    )
    print(f"✓ Got {len(results['ids'])} questions\n")
except Exception as e:
    print(f"✗ Error: {e}\n")

# Test 5: $and clause with two conditions
print("Test 5: $and clause - difficulty=medium AND type=text")
try:
    results = client.collection.get(
        where={"$and": [{"difficulty": "medium"}, {"type": "text"}]},
        limit=5
    )
    print(f"✓ Got {len(results['ids'])} questions\n")
except Exception as e:
    print(f"✗ Error: {e}\n")

# Test 6: Query with embedding (semantic search)
print("Test 6: Query with embedding")
try:
    from quiz_shared.utils.embeddings import generate_embedding
    embedding = generate_embedding("geography questions")
    results = client.collection.query(
        query_embeddings=[embedding],
        n_results=5
    )
    print(f"✓ Got {len(results['ids'][0])} questions")
    print(f"  Questions: {[doc[:40] + '...' for doc in results['documents'][0]]}\n")
except Exception as e:
    print(f"✗ Error: {e}\n")

# Test 7: Query with embedding AND where clause
print("Test 7: Query with embedding AND where clause")
try:
    embedding = generate_embedding("geography questions")
    results = client.collection.query(
        query_embeddings=[embedding],
        where={"type": "text"},
        n_results=5
    )
    print(f"✓ Got {len(results['ids'][0])} questions\n")
except Exception as e:
    print(f"✗ Error: {e}\n")

# Test 8: Using search_questions method (simple)
print("Test 8: search_questions method - type=text only")
try:
    questions = client.search_questions(
        query_text=None,
        filters={"type": "text"},
        n_results=5
    )
    print(f"✓ Got {len(questions)} questions\n")
except Exception as e:
    print(f"✗ Error: {e}\n")

# Test 9: Using search_questions method (with difficulty)
print("Test 9: search_questions method - difficulty=medium, type=text")
try:
    questions = client.search_questions(
        query_text=None,
        filters={"difficulty": "medium", "type": "text"},
        n_results=5
    )
    print(f"✓ Got {len(questions)} questions\n")
except Exception as e:
    print(f"✗ Error: {e}\n")

print("=== Test Complete ===")
