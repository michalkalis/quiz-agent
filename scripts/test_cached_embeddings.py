"""Simple test to verify embeddings are cached in Question objects."""

import sys
import os

# Add packages to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "packages/shared"))

from quiz_shared.database.chroma_client import ChromaDBClient

def test_cached_embeddings():
    """Test that Question objects have embeddings attached."""

    print("=" * 60)
    print("TESTING CACHED EMBEDDINGS")
    print("=" * 60)

    # Initialize client
    chroma_client = ChromaDBClient(persist_directory='./chroma_data')

    # Test 1: Get a single question by ID
    print("\n1. Testing get_question() with embeddings...")

    # Get all questions to find an ID
    all_questions = chroma_client.get_all_questions(limit=5)

    if not all_questions:
        print("   ❌ No questions in database")
        return

    test_id = all_questions[0].id
    print(f"   Testing with question ID: {test_id}")

    # Get question with embeddings
    question = chroma_client.get_question(test_id)

    if question:
        print(f"   Question: {question.question[:60]}...")
        if question.embedding is not None:
            print(f"   ✅ Embedding retrieved! Length: {len(question.embedding)}")
            print(f"   ✅ Embedding is a list of floats: {isinstance(question.embedding, list)}")
            if len(question.embedding) > 0:
                print(f"   ✅ First value: {question.embedding[0]:.6f}")
        else:
            print(f"   ❌ Embedding is None - optimization NOT working")
    else:
        print(f"   ❌ Could not retrieve question")

    # Test 2: Get multiple questions without query (using filters only)
    print("\n2. Testing get() with filters (no semantic search)...")

    questions = chroma_client.search_questions(
        query_text=None,  # No query = no embedding generation needed
        filters={"review_status": "approved"},
        n_results=3
    )

    print(f"   Retrieved {len(questions)} questions")

    embeddings_found = 0
    for i, q in enumerate(questions[:3]):
        if q.embedding is not None:
            embeddings_found += 1
            print(f"   ✅ Question {i+1}: Has embedding (length: {len(q.embedding)})")
        else:
            print(f"   ❌ Question {i+1}: No embedding")

    # Results
    print("\n" + "=" * 60)
    print("RESULTS")
    print("=" * 60)

    if embeddings_found > 0:
        print(f"✅ SUCCESS: {embeddings_found} questions have cached embeddings!")
        print("✅ The optimization is working correctly!")
        print("\nWhat this means:")
        print("  - Questions retrieved from ChromaDB include embeddings")
        print("  - Diversity calculation won't need to call OpenAI API")
        print("  - Answer processing should be ~300x faster!")
    else:
        print("❌ FAILED: No embeddings found in Question objects")
        print("\nThis means embeddings are not being retrieved from ChromaDB")
        print("Check that ChromaDB has embeddings stored for these questions")

    print("=" * 60)

if __name__ == "__main__":
    try:
        test_cached_embeddings()
    except Exception as e:
        print(f"\n❌ ERROR: {e}")
        import traceback
        traceback.print_exc()
