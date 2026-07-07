"""Evaluate RAG retrieval quality: semantic search vs random baseline.

Compares question selection strategies across test scenarios to verify
that semantic search outperforms random selection on diversity and
preference adherence metrics.

Usage:
    python scripts/evaluate_rag_quality.py [--chroma-path ./chroma_data] [--n-questions 10]
"""

import argparse
import random
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional

from dotenv import load_dotenv

# Load .env from project root
load_dotenv(Path(__file__).resolve().parent.parent / ".env")

# Add packages to path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "packages" / "shared"))

from quiz_shared.database.chroma_client import ChromaDBClient
from quiz_shared.models.question import Question
from quiz_shared.utils.embeddings import generate_embedding, calculate_similarity


@dataclass
class Scenario:
    """A test scenario for evaluating retrieval quality."""

    name: str
    description: str
    semantic_query: str
    filters: dict
    preferred_topics: list = field(default_factory=list)
    disliked_topics: list = field(default_factory=list)


@dataclass
class Metrics:
    """Evaluation metrics for a retrieval run."""

    topic_diversity: float = 0.0  # unique topics / total questions
    semantic_diversity: float = 0.0  # avg cosine distance between consecutive Qs
    preference_adherence: float = 0.0  # % matching preferred topics
    dislike_avoidance: float = 0.0  # % NOT matching disliked topics


SCENARIOS = [
    Scenario(
        name="No preferences",
        description="Pure diversity test with no topic preferences",
        semantic_query="interesting and varied quiz question",
        filters={"type": "text", "review_status": "approved"},
    ),
    Scenario(
        name="Preferred: Science",
        description="User prefers science questions",
        semantic_query="interesting science question about physics chemistry or biology",
        filters={"type": "text", "review_status": "approved"},
        preferred_topics=["Science", "Physics", "Chemistry", "Biology"],
    ),
    Scenario(
        name="Disliked: Geography",
        description="User dislikes geography questions",
        semantic_query="interesting quiz question avoiding geography and maps",
        filters={"type": "text", "review_status": "approved"},
        disliked_topics=["Geography"],
    ),
    Scenario(
        name="Mixed preferences",
        description="User prefers history, dislikes sports",
        semantic_query="interesting history question avoiding sports and athletics",
        filters={"type": "text", "review_status": "approved"},
        preferred_topics=["History"],
        disliked_topics=["Sports"],
    ),
]


def retrieve_semantic(
    chroma: ChromaDBClient,
    scenario: Scenario,
    n_questions: int,
) -> List[Question]:
    """Retrieve questions using semantic search."""
    return chroma.search_questions(
        query_text=scenario.semantic_query,
        filters=scenario.filters,
        n_results=n_questions,
    )


def retrieve_random(
    chroma: ChromaDBClient,
    scenario: Scenario,
    n_questions: int,
) -> List[Question]:
    """Retrieve questions using random selection with same filters."""
    # Get all matching questions, then randomly sample
    all_matching = chroma.search_questions(
        query_text=None,
        filters=scenario.filters,
        n_results=500,
    )
    if len(all_matching) <= n_questions:
        return all_matching
    return random.sample(all_matching, n_questions)


def compute_metrics(
    questions: List[Question],
    scenario: Scenario,
) -> Metrics:
    """Compute evaluation metrics for a set of retrieved questions.

    Metrics:
    - topic_diversity: unique topics / total questions (1.0 = every question different topic)
    - semantic_diversity: avg cosine distance between consecutive questions
    - preference_adherence: fraction of questions matching preferred topics (if any)
    - dislike_avoidance: fraction of questions NOT matching disliked topics (if any)
    """
    if not questions:
        return Metrics()

    total = len(questions)
    topics = [q.topic for q in questions]

    # Topic diversity: unique topics / total
    topic_diversity = len(set(topics)) / total

    # Semantic diversity: average cosine distance between consecutive questions
    distances = []
    for i in range(len(questions) - 1):
        emb_a = questions[i].embedding
        emb_b = questions[i + 1].embedding
        if emb_a is not None and emb_b is not None:
            sim = calculate_similarity(emb_a, emb_b)
            distances.append(1.0 - sim)
    semantic_diversity = sum(distances) / len(distances) if distances else 0.0

    # Preference adherence
    if scenario.preferred_topics:
        preferred_lower = [t.lower() for t in scenario.preferred_topics]
        matching = sum(1 for q in questions if q.topic.lower() in preferred_lower)
        preference_adherence = matching / total
    else:
        preference_adherence = -1.0  # N/A

    # Dislike avoidance
    if scenario.disliked_topics:
        disliked_lower = [t.lower() for t in scenario.disliked_topics]
        avoided = sum(1 for q in questions if q.topic.lower() not in disliked_lower)
        dislike_avoidance = avoided / total
    else:
        dislike_avoidance = -1.0  # N/A

    return Metrics(
        topic_diversity=topic_diversity,
        semantic_diversity=semantic_diversity,
        preference_adherence=preference_adherence,
        dislike_avoidance=dislike_avoidance,
    )


def format_metric(value: float, label: str) -> str:
    """Format a single metric for display."""
    if value < 0:
        return f"  {label}: N/A"
    return f"  {label}: {value:.2%}"


def run_evaluation(chroma_path: str, n_questions: int) -> None:
    """Run the full evaluation across all scenarios."""
    chroma = ChromaDBClient(persist_directory=chroma_path)
    total_questions = chroma.count_questions()
    print(f"Database: {total_questions} total questions\n")

    if total_questions == 0:
        print("ERROR: No questions in database. Nothing to evaluate.")
        sys.exit(1)

    wins = {"semantic": 0, "random": 0, "tie": 0}

    for scenario in SCENARIOS:
        print(f"{'=' * 60}")
        print(f"Scenario: {scenario.name}")
        print(f"  {scenario.description}")
        print(f"  Query: \"{scenario.semantic_query}\"")
        print()

        # Retrieve with both strategies
        semantic_qs = retrieve_semantic(chroma, scenario, n_questions)
        random_qs = retrieve_random(chroma, scenario, n_questions)

        print(f"  Retrieved: {len(semantic_qs)} semantic, {len(random_qs)} random")

        # Compute metrics
        sem_metrics = compute_metrics(semantic_qs, scenario)
        rand_metrics = compute_metrics(random_qs, scenario)

        # Display comparison
        print(f"\n  {'Metric':<25} {'Semantic':>10} {'Random':>10} {'Winner':>10}")
        print(f"  {'-' * 55}")

        comparisons = [
            ("Topic diversity", sem_metrics.topic_diversity, rand_metrics.topic_diversity),
            ("Semantic diversity", sem_metrics.semantic_diversity, rand_metrics.semantic_diversity),
        ]
        if scenario.preferred_topics:
            comparisons.append(
                ("Preference adherence", sem_metrics.preference_adherence, rand_metrics.preference_adherence)
            )
        if scenario.disliked_topics:
            comparisons.append(
                ("Dislike avoidance", sem_metrics.dislike_avoidance, rand_metrics.dislike_avoidance)
            )

        scenario_sem_wins = 0
        scenario_rand_wins = 0
        for label, sem_val, rand_val in comparisons:
            if sem_val < 0 or rand_val < 0:
                winner = "N/A"
            elif sem_val > rand_val + 0.01:
                winner = "semantic"
                scenario_sem_wins += 1
            elif rand_val > sem_val + 0.01:
                winner = "random"
                scenario_rand_wins += 1
            else:
                winner = "tie"

            sem_str = f"{sem_val:.2%}" if sem_val >= 0 else "N/A"
            rand_str = f"{rand_val:.2%}" if rand_val >= 0 else "N/A"
            print(f"  {label:<25} {sem_str:>10} {rand_str:>10} {winner:>10}")

        if scenario_sem_wins > scenario_rand_wins:
            wins["semantic"] += 1
            print(f"\n  Scenario winner: SEMANTIC ({scenario_sem_wins}/{scenario_sem_wins + scenario_rand_wins})")
        elif scenario_rand_wins > scenario_sem_wins:
            wins["random"] += 1
            print(f"\n  Scenario winner: RANDOM ({scenario_rand_wins}/{scenario_sem_wins + scenario_rand_wins})")
        else:
            wins["tie"] += 1
            print(f"\n  Scenario winner: TIE")
        print()

    # Summary
    print(f"{'=' * 60}")
    print(f"OVERALL RESULTS")
    print(f"  Semantic wins: {wins['semantic']}/{len(SCENARIOS)}")
    print(f"  Random wins:   {wins['random']}/{len(SCENARIOS)}")
    print(f"  Ties:          {wins['tie']}/{len(SCENARIOS)}")

    if wins["semantic"] > wins["random"]:
        print("\n  Semantic search outperforms random baseline.")
    elif wins["random"] > wins["semantic"]:
        print("\n  WARNING: Random baseline outperforms semantic search!")
        print("  Consider reviewing your semantic query construction.")
    else:
        print("\n  No clear winner. Consider increasing n_questions for more signal.")


def main():
    parser = argparse.ArgumentParser(description="Evaluate RAG retrieval quality")
    parser.add_argument(
        "--chroma-path",
        default="./chroma_data",
        help="Path to ChromaDB persistent storage (default: ./chroma_data)",
    )
    parser.add_argument(
        "--n-questions",
        type=int,
        default=10,
        help="Number of questions to retrieve per scenario (default: 10)",
    )
    args = parser.parse_args()

    run_evaluation(args.chroma_path, args.n_questions)


if __name__ == "__main__":
    main()
