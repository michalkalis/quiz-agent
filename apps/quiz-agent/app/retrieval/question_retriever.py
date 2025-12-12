"""RAG-based question retrieval with semantic search.

Uses ChromaDB for intelligent question selection based on:
- Semantic topic matching ("space questions" finds astronomy, NASA, planets)
- Difficulty filtering
- Category preferences (adults, children, etc.)
- Question type (text, multichoice)
- Previously asked questions exclusion
"""

from typing import List, Optional
import random

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../../..", "packages/shared"))

from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession
from quiz_shared.database.chroma_client import ChromaDBClient


class QuestionRetriever:
    """Retrieves questions using RAG with semantic search."""

    def __init__(self, chroma_client: Optional[ChromaDBClient] = None):
        """Initialize question retriever.

        Args:
            chroma_client: ChromaDB client (or create default)
        """
        self.chroma = chroma_client or ChromaDBClient()

    def get_next_question(
        self,
        session: QuizSession,
        n_candidates: int = 20
    ) -> Optional[Question]:
        """Get next question for quiz session using RAG.

        Args:
            session: Current quiz session
            n_candidates: Number of candidates to retrieve (higher = more variety)

        Returns:
            Selected question or None if no matches

        Example:
            >>> retriever = QuestionRetriever()
            >>> question = retriever.get_next_question(session)
        """
        # Build semantic query from preferences
        query_text = None
        if session.preferred_topics:
            query_text = " ".join(session.preferred_topics)

        # Build metadata filters
        filters = {
            "difficulty": session.current_difficulty,
            "type": "text",  # MVP: only text questions
        }

        # Add category filter
        if session.preferred_categories:
            filters["category"] = {"$in": session.preferred_categories}
        elif session.excluded_categories:
            filters["category"] = {"$nin": session.excluded_categories}
        else:
            # Default to non-children categories
            filters["category"] = {"$nin": ["children"]}

        # Exclude already asked questions
        excluded_ids = session.asked_question_ids

        # Query ChromaDB
        candidates = self.chroma.search_questions(
            query_text=query_text,
            filters=filters,
            n_results=n_candidates,
            excluded_ids=excluded_ids
        )

        if not candidates:
            # Fallback: try without topic preference
            candidates = self.chroma.search_questions(
                query_text=None,
                filters=filters,
                n_results=n_candidates,
                excluded_ids=excluded_ids
            )

        if not candidates:
            return None

        # Select question with diversity
        selected = self._select_diverse_question(candidates, session)

        return selected

    def _select_diverse_question(
        self,
        candidates: List[Question],
        session: QuizSession
    ) -> Question:
        """Select question that maximizes topic diversity.

        Avoids repeating the same topic consecutively.

        Args:
            candidates: Candidate questions
            session: Current session

        Returns:
            Selected question
        """
        if not candidates:
            return None

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

        # Randomly select from diverse candidates for variety
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

        return self.chroma.search_questions(
            query_text=query,
            filters=filters,
            n_results=limit
        )
