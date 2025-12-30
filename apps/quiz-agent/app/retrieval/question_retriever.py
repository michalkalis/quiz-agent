"""RAG-based question retrieval with semantic search as PRIMARY mechanism.

Proper RAG Implementation:
- Builds rich semantic queries from session context
- Uses embeddings to find semantically relevant and diverse questions
- Leverages semantic similarity for topic matching and diversity
- Metadata filters are constraints, not primary selection criteria
"""

from typing import List, Optional, Tuple
import random

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../../..", "packages/shared"))

from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession
from quiz_shared.database.chroma_client import ChromaDBClient
from quiz_shared.utils.embeddings import generate_embedding, calculate_similarity


class QuestionRetriever:
    """Retrieves questions using proper RAG with semantic search."""

    def __init__(self, chroma_client: Optional[ChromaDBClient] = None):
        """Initialize question retriever.

        Args:
            chroma_client: ChromaDB client (or create default)
        """
        self.chroma = chroma_client or ChromaDBClient()

    def get_next_question(
        self,
        session: QuizSession,
        n_candidates: int = 50,  # Fetch more for better semantic selection
        client_excluded_ids: Optional[List[str]] = None
    ) -> Optional[Question]:
        """Get next question using RAG-first approach.

        Proper RAG: Semantic search is PRIMARY, metadata are constraints.

        Args:
            session: Current quiz session
            n_candidates: Number of candidates to retrieve (higher = better diversity)
            client_excluded_ids: Question IDs excluded by client (cross-session history)

        Returns:
            Selected question or None if no matches

        Example:
            >>> retriever = QuestionRetriever()
            >>> question = retriever.get_next_question(session)
        """
        # Step 1: Build rich semantic query from session context
        semantic_query = self._build_semantic_query(session)
        print(f"DEBUG: Semantic query: '{semantic_query}'")

        # Step 2: Determine difficulty (handle "random")
        question_difficulty = self._determine_difficulty(session)

        # Step 3: Build metadata filters (as CONSTRAINTS, not primary selection)
        filters = self._build_metadata_filters(question_difficulty, session)

        # Step 4: Merge session-scoped and client-side exclusions
        session_excluded = session.asked_question_ids
        client_excluded = client_excluded_ids or []
        all_excluded_ids = list(set(session_excluded + client_excluded))

        print(f"DEBUG: Excluding {len(all_excluded_ids)} questions total")
        print(f"  - Session: {len(session_excluded)}")
        print(f"  - Client history: {len(client_excluded)}")

        # Step 5: Retrieve candidates using semantic search (PRIMARY mechanism)
        candidates = self._retrieve_candidates_semantic(
            semantic_query=semantic_query,
            filters=filters,
            n_candidates=n_candidates,
            excluded_ids=all_excluded_ids
        )

        if not candidates:
            print(f"DEBUG: No candidates from semantic search, trying fallback strategies")
            candidates = self._fallback_retrieval(
                session,
                question_difficulty,
                n_candidates,
                all_excluded_ids
            )

        if not candidates:
            return self._handle_no_candidates(session, question_difficulty)

        # Step 5: Select best question using semantic diversity scoring
        selected = self._select_with_semantic_diversity(candidates, session)

        return selected

    def _build_semantic_query(self, session: QuizSession) -> str:
        """Build rich semantic query from session context.

        This is the key to proper RAG: construct meaningful semantic queries
        that describe what we're looking for, not just keyword matching.

        Args:
            session: Current quiz session

        Returns:
            Rich semantic query string

        Example:
            "interesting science question about physics, avoiding biology and chemistry topics"
        """
        query_parts = []

        # Add difficulty descriptor (semantic, not just filter)
        difficulty_descriptors = {
            "easy": "accessible and straightforward",
            "medium": "moderately challenging",
            "hard": "advanced and complex",
            "random": "engaging"  # Generic for random
        }
        diff_descriptor = difficulty_descriptors.get(session.current_difficulty, "interesting")
        query_parts.append(diff_descriptor)

        # Add topic preferences (semantic matching)
        if session.preferred_topics:
            topics_str = ", ".join(session.preferred_topics)
            query_parts.append(f"question about {topics_str}")
        else:
            query_parts.append("question")

        # Add diversity hint based on recent topics
        if session.current_topic:
            query_parts.append(f"different from {session.current_topic}")

        # Add exclusions semantically (find topics distant from these)
        if session.disliked_topics:
            disliked_str = " and ".join(session.disliked_topics)
            query_parts.append(f"avoiding {disliked_str}")

        # Construct final query
        semantic_query = " ".join(query_parts)
        return semantic_query

    def _determine_difficulty(self, session: QuizSession) -> str:
        """Determine difficulty for this question.

        Args:
            session: Current quiz session

        Returns:
            Difficulty level (easy/medium/hard)
        """
        question_difficulty = session.current_difficulty
        if question_difficulty == "random":
            question_difficulty = random.choice(["easy", "medium", "hard"])
            print(f"DEBUG: Selected random difficulty: {question_difficulty}")
        return question_difficulty

    def _build_metadata_filters(
        self,
        difficulty: str,
        session: QuizSession
    ) -> dict:
        """Build metadata filters as CONSTRAINTS (not primary selection).

        Args:
            difficulty: Difficulty level
            session: Current quiz session

        Returns:
            Metadata filters dict
        """
        filters = {
            "difficulty": difficulty,
            "type": "text",  # MVP: only text questions
            "review_status": "approved",  # ONLY use human-reviewed approved questions
        }

        # Add category filter if specified
        if session.preferred_categories:
            filters["category"] = {"$in": session.preferred_categories}

        return filters

    def _retrieve_candidates_semantic(
        self,
        semantic_query: str,
        filters: dict,
        n_candidates: int,
        excluded_ids: List[str]
    ) -> List[Question]:
        """Retrieve candidates using semantic search as PRIMARY mechanism.

        Args:
            semantic_query: Rich semantic query
            filters: Metadata constraints
            n_candidates: Number of candidates
            excluded_ids: IDs to exclude

        Returns:
            List of candidate questions
        """
        # ALWAYS use semantic search (RAG-first approach)
        candidates = self.chroma.search_questions(
            query_text=semantic_query,  # Always provide semantic query
            filters=filters,
            n_results=n_candidates,
            excluded_ids=excluded_ids
        )

        print(f"DEBUG: Retrieved {len(candidates)} candidates via semantic search")
        return candidates

    def _fallback_retrieval(
        self,
        session: QuizSession,
        question_difficulty: str,
        n_candidates: int,
        excluded_ids: List[str]
    ) -> List[Question]:
        """Fallback retrieval strategies when primary semantic search fails.

        Args:
            session: Current quiz session
            question_difficulty: Difficulty level
            n_candidates: Number of candidates
            excluded_ids: Question IDs to exclude (merged session + client)

        Returns:
            List of candidate questions
        """

        # Fallback 1: Simpler semantic query (just "question")
        print(f"DEBUG: Fallback 1 - Simpler semantic query")
        simple_query = "quiz question"
        candidates = self.chroma.search_questions(
            query_text=simple_query,
            filters={"difficulty": question_difficulty, "type": "text", "review_status": "approved"},
            n_results=n_candidates,
            excluded_ids=excluded_ids
        )
        if candidates:
            return candidates

        # Fallback 2: Try other difficulty levels with semantic search
        print(f"DEBUG: Fallback 2 - Other difficulties with semantic search")
        difficulty_fallback = ["easy", "medium", "hard"]
        if question_difficulty in difficulty_fallback:
            difficulty_fallback.remove(question_difficulty)

        for fallback_difficulty in difficulty_fallback:
            candidates = self.chroma.search_questions(
                query_text=simple_query,
                filters={"difficulty": fallback_difficulty, "type": "text", "review_status": "approved"},
                n_results=n_candidates,
                excluded_ids=excluded_ids
            )
            if candidates:
                print(f"DEBUG: Found {len(candidates)} candidates with difficulty {fallback_difficulty}")
                return candidates

        # Fallback 3: Minimal constraints (still require approved)
        print(f"DEBUG: Fallback 3 - Minimal constraints")
        candidates = self.chroma.search_questions(
            query_text="question",
            filters={"type": "text", "review_status": "approved"},
            n_results=n_candidates,
            excluded_ids=excluded_ids
        )

        return candidates

    def _handle_no_candidates(
        self,
        session: QuizSession,
        question_difficulty: str
    ) -> None:
        """Handle case when no candidates found.

        Args:
            session: Current quiz session
            question_difficulty: Difficulty level

        Returns:
            None
        """
        total_count = self.chroma.count_questions()
        if total_count == 0:
            print(f"ERROR: Database is empty. No questions found.")
        else:
            print(f"ERROR: No questions available. Database has {total_count} questions.")
            print(f"  - Asked: {len(session.asked_question_ids)} questions")
            print(f"  - Difficulty: {question_difficulty}")
        return None

    def _select_with_semantic_diversity(
        self,
        candidates: List[Question],
        session: QuizSession
    ) -> Question:
        """Select question using semantic diversity scoring.

        Proper RAG: Use embeddings to measure semantic distance from recent questions.
        Prefer questions that are semantically diverse from what was recently asked.

        Args:
            candidates: Candidate questions
            session: Current session

        Returns:
            Selected question
        """
        if not candidates:
            return None

        # If no questions asked yet, just pick randomly
        if not session.asked_question_ids:
            return random.choice(candidates)

        # Get recently asked questions for diversity comparison
        recent_questions = self._get_recent_questions(session, limit=3)

        if not recent_questions:
            # If can't retrieve recent questions, fall back to topic-based diversity
            return self._select_diverse_by_topic(candidates, session)

        # Score each candidate by semantic diversity
        scored_candidates = []
        for candidate in candidates:
            diversity_score = self._calculate_semantic_diversity(
                candidate, recent_questions
            )
            scored_candidates.append((candidate, diversity_score))

        # Sort by diversity score (higher = more diverse = better)
        scored_candidates.sort(key=lambda x: x[1], reverse=True)

        # Select from top 5 most diverse to maintain some randomness
        top_diverse = scored_candidates[:5]
        selected, score = random.choice(top_diverse)

        print(f"DEBUG: Selected question with diversity score {score:.3f}")
        return selected

    def _get_recent_questions(
        self,
        session: QuizSession,
        limit: int = 3
    ) -> List[Question]:
        """Get recently asked questions from session.

        Args:
            session: Current session
            limit: Number of recent questions to retrieve

        Returns:
            List of recent Question objects
        """
        if not session.asked_question_ids:
            return []

        # Get last N question IDs
        recent_ids = session.asked_question_ids[-limit:]

        # Retrieve question objects
        recent_questions = []
        for qid in recent_ids:
            question = self.chroma.get_question(qid)
            if question:
                recent_questions.append(question)

        return recent_questions

    def _calculate_semantic_diversity(
        self,
        candidate: Question,
        recent_questions: List[Question]
    ) -> float:
        """Calculate semantic diversity score for a candidate.

        Higher score = more diverse = better for variety.

        Args:
            candidate: Candidate question
            recent_questions: Recently asked questions

        Returns:
            Diversity score (0.0 to 1.0, higher is more diverse)
        """
        # Use cached embedding if available, otherwise generate
        if candidate.embedding is not None:
            candidate_embedding = candidate.embedding
        else:
            candidate_embedding = generate_embedding(candidate.question)

        # Calculate average distance from recent questions
        distances = []
        for recent_q in recent_questions:
            # Use cached embedding if available, otherwise generate
            if recent_q.embedding is not None:
                recent_embedding = recent_q.embedding
            else:
                recent_embedding = generate_embedding(recent_q.question)

            similarity = calculate_similarity(candidate_embedding, recent_embedding)
            # Distance = 1 - similarity (higher distance = more diverse)
            distance = 1.0 - similarity
            distances.append(distance)

        # Average distance is the diversity score
        diversity_score = sum(distances) / len(distances) if distances else 0.5

        return diversity_score

    def _select_diverse_by_topic(
        self,
        candidates: List[Question],
        session: QuizSession
    ) -> Question:
        """Fallback diversity selection using topic matching.

        Args:
            candidates: Candidate questions
            session: Current session

        Returns:
            Selected question
        """
        # Get recent topics
        recent_topics = []
        if session.current_topic:
            recent_topics.append(session.current_topic)

        # Filter out recent topics if possible
        diverse_candidates = [
            q for q in candidates
            if q.topic not in recent_topics
        ]

        # If all candidates are recent topics, use all
        if not diverse_candidates:
            diverse_candidates = candidates

        # Randomly select from diverse candidates
        return random.choice(diverse_candidates)

    def search_questions(
        self,
        query: Optional[str] = None,
        difficulty: Optional[str] = None,
        topic: Optional[str] = None,
        category: Optional[str] = None,
        limit: int = 10
    ) -> List[Question]:
        """Search questions with filters.

        Args:
            query: Semantic search query
            difficulty: Filter by difficulty
            topic: Filter by topic
            category: Filter by category
            limit: Max results

        Returns:
            Matching questions
        """
        filters = {}
        if difficulty:
            filters["difficulty"] = difficulty
        if topic:
            filters["topic"] = topic
        if category:
            filters["category"] = category

        # Always use semantic search if no query provided
        if not query:
            query = "quiz question"

        return self.chroma.search_questions(
            query_text=query,
            filters=filters,
            n_results=limit
        )
