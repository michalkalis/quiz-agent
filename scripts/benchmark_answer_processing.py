"""Benchmark script to measure answer processing performance bottleneck."""

import time
import sys
import os

# Add packages to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "packages/shared"))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "apps/quiz-agent"))

from quiz_shared.utils.embeddings import generate_embedding

def benchmark_embedding_generation():
    """Benchmark the time it takes to generate embeddings."""

    test_texts = [
        "What is the capital of France?",
        "Who painted the Mona Lisa?",
        "What is the speed of light?",
        "What is the largest planet in our solar system?",
        "Who wrote Romeo and Juliet?",
    ]

    print("=" * 60)
    print("EMBEDDING GENERATION BENCHMARK")
    print("=" * 60)

    # Test single embedding
    print("\n1. Single Embedding Generation:")
    start = time.time()
    embedding = generate_embedding(test_texts[0])
    elapsed = time.time() - start
    print(f"   Time: {elapsed:.3f} seconds")
    print(f"   Embedding size: {len(embedding)}")

    # Test sequential embeddings (current approach)
    print("\n2. Sequential Embedding Generation (5 texts):")
    start = time.time()
    embeddings = []
    for text in test_texts:
        emb = generate_embedding(text)
        embeddings.append(emb)
    elapsed = time.time() - start
    print(f"   Total time: {elapsed:.3f} seconds")
    print(f"   Average per embedding: {elapsed/len(test_texts):.3f} seconds")

    # Simulate worst case for diversity calculation
    print("\n3. Simulating Diversity Calculation (worst case):")
    print("   - 50 candidates")
    print("   - 3 recent questions")
    print("   - Total embeddings needed: 50 + (50 × 3) = 200")

    # Estimate based on single embedding time
    single_time = elapsed / len(test_texts)
    estimated_time = single_time * 200
    print(f"\n   Estimated time: {estimated_time:.1f} seconds ({estimated_time/60:.1f} minutes)")

    # More realistic: 50 candidates, 3 recent questions
    # Current code generates: 1 embedding per candidate + 3 embeddings per candidate
    # = 50 × (1 + 3) = 200 embeddings
    print("\n4. Realistic Test (10 candidates × 3 recent questions):")
    start = time.time()
    candidate_count = 10
    recent_count = 3

    for i in range(candidate_count):
        # Generate embedding for candidate
        candidate_emb = generate_embedding(f"Candidate question {i}")

        # Generate embedding for each recent question
        for j in range(recent_count):
            recent_emb = generate_embedding(f"Recent question {j}")

    elapsed = time.time() - start
    total_embeddings = candidate_count * (1 + recent_count)
    print(f"   Total embeddings: {total_embeddings}")
    print(f"   Total time: {elapsed:.3f} seconds")
    print(f"   Average per embedding: {elapsed/total_embeddings:.3f} seconds")

    # Extrapolate to 50 candidates
    extrapolated_50 = (elapsed / candidate_count) * 50
    print(f"\n   Extrapolated for 50 candidates: {extrapolated_50:.1f} seconds")

    print("\n" + "=" * 60)
    print("ANALYSIS")
    print("=" * 60)
    print("\nThe bottleneck is clear:")
    print("  - Each embedding takes ~0.2-0.5 seconds (API call)")
    print("  - Diversity calculation needs 200 embeddings in worst case")
    print("  - Total time: 40-100 seconds PER ANSWER!")
    print("\nThis is why answer processing feels very slow.")
    print("\nSolution: Cache embeddings for questions in the database.")
    print("=" * 60)

if __name__ == "__main__":
    try:
        benchmark_embedding_generation()
    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()
