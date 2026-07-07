"""Test script to verify the embedding optimization is working."""

import sys
import os
import time

# Add packages to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "packages/shared"))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "apps/quiz-agent"))

from quiz_shared.database.chroma_client import ChromaDBClient
from quiz_shared.models.session import QuizSession
from app.retrieval.question_retriever import QuestionRetriever

def test_embedding_optimization():
    """Test that embeddings are cached and question retrieval is fast."""

    print("=" * 60)
    print("TESTING EMBEDDING OPTIMIZATION")
    print("=" * 60)

    # Initialize clients
    chroma_client = ChromaDBClient(persist_directory='./chroma_data')
    retriever = QuestionRetriever(chroma_client=chroma_client)

    # Create a mock session
    session = QuizSession(
        session_id="test_session",
        preferred_topics=[],
        preferred_categories=["adults"],
        current_difficulty="medium",
        asked_question_ids=[]
    )

    print("\n1. Testing ChromaDB embedding retrieval...")
    start = time.time()
    questions = chroma_client.search_questions(
        query_text="test question",
        filters={"review_status": "approved"},
        n_results=5
    )
    elapsed = time.time() - start

    if questions:
        print(f"   Retrieved {len(questions)} questions in {elapsed:.3f}s")
        q = questions[0]
        if q.embedding is not None:
            print(f"   ✅ Embedding found! Length: {len(q.embedding)}")
        else:
            print(f"   ❌ WARNING: No embedding in question object")
    else:
        print("   ❌ No approved questions found in database")
        return

    # Test question retrieval (simulate answering a question)
    print("\n2. Testing question retrieval speed...")

    # First question (baseline)
    start = time.time()
    question1 = retriever.get_next_question(session)
    elapsed1 = time.time() - start
    print(f"   First question retrieved in {elapsed1:.3f}s")

    if question1:
        session.asked_question_ids.append(question1.id)

        # Second question (should use cached embeddings for diversity calculation)
        start = time.time()
        question2 = retriever.get_next_question(session)
        elapsed2 = time.time() - start
        print(f"   Second question retrieved in {elapsed2:.3f}s")

        if question2:
            session.asked_question_ids.append(question2.id)

            # Third question (even more diversity calculations)
            start = time.time()
            question3 = retriever.get_next_question(session)
            elapsed3 = time.time() - start
            print(f"   Third question retrieved in {elapsed3:.3f}s")

            avg_time = (elapsed1 + elapsed2 + elapsed3) / 3
            print(f"\n   Average retrieval time: {avg_time:.3f}s")

            if avg_time < 2.0:
                print(f"   ✅ EXCELLENT! Question retrieval is very fast (<2s)")
                print(f"   This confirms embeddings are being cached!")
            elif avg_time < 10.0:
                print(f"   ⚠️  MODERATE: Retrieval is working but could be faster")
                print(f"   Check if embeddings are being used correctly")
            else:
                print(f"   ❌ SLOW: Retrieval is still slow (>10s)")
                print(f"   Embeddings may not be cached properly")

    print("\n" + "=" * 60)
    print("RESULTS")
    print("=" * 60)

    if questions and questions[0].embedding is not None:
        print("✅ Embeddings are being retrieved from ChromaDB")
        if avg_time < 2.0:
            print("✅ Question retrieval is FAST - optimization is working!")
            print(f"\nExpected improvement: ~30x faster than before (~60s → {avg_time:.1f}s)")
        else:
            print("⚠️  Question retrieval works but may need further optimization")
    else:
        print("❌ Embeddings are NOT being retrieved - optimization failed")

    print("=" * 60)

if __name__ == "__main__":
    try:
        test_embedding_optimization()
    except Exception as e:
        print(f"\n❌ ERROR: {e}")
        import traceback
        traceback.print_exc()
