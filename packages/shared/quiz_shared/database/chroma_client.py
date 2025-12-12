"""ChromaDB client for question storage with RAG capabilities."""

import chromadb
from chromadb.config import Settings
from typing import List, Dict, Optional, Any
from datetime import datetime
import json

from ..models.question import Question
from ..utils.embeddings import generate_embedding, calculate_similarity


class ChromaDBClient:
    """Client for interacting with ChromaDB for question storage.

    Provides semantic search, duplicate detection, and RAG functionality.
    """

    def __init__(
        self,
        persist_directory: str = "./chroma_data",
        collection_name: str = "quiz_questions"
    ):
        """Initialize ChromaDB client.

        Args:
            persist_directory: Directory to persist ChromaDB data
            collection_name: Name of collection for questions
        """
        self.client = chromadb.Client(Settings(
            persist_directory=persist_directory,
            anonymized_telemetry=False
        ))
        self.collection_name = collection_name
        self.collection = self._get_or_create_collection()

    def _get_or_create_collection(self):
        """Get or create the questions collection."""
        try:
            return self.client.get_collection(self.collection_name)
        except Exception:
            return self.client.create_collection(
                name=self.collection_name,
                metadata={"description": "Pub quiz questions with embeddings"}
            )

    def add_question(self, question: Question) -> bool:
        """Add a question to ChromaDB.

        Args:
            question: Question object to add

        Returns:
            True if successful, False otherwise
        """
        try:
            # Generate embedding for question text
            embedding = generate_embedding(question.question)

            # Prepare metadata (all fields except question text)
            metadata = {
                "type": question.type,
                "correct_answer": question.correct_answer if isinstance(question.correct_answer, str) else json.dumps(question.correct_answer),
                "topic": question.topic,
                "category": question.category,
                "difficulty": question.difficulty,
                "tags": json.dumps(question.tags),
                "created_at": question.created_at.isoformat(),
                "source": question.source,
                "usage_count": question.usage_count,
                "user_ratings": json.dumps(question.user_ratings),
            }

            # Add optional fields
            if question.possible_answers:
                metadata["possible_answers"] = json.dumps(question.possible_answers)
            if question.alternative_answers:
                metadata["alternative_answers"] = json.dumps(question.alternative_answers)
            if question.created_by:
                metadata["created_by"] = question.created_by
            if question.media_url:
                metadata["media_url"] = question.media_url
            if question.media_duration_seconds:
                metadata["media_duration_seconds"] = question.media_duration_seconds
            if question.explanation:
                metadata["explanation"] = question.explanation

            # Add to collection
            self.collection.add(
                ids=[question.id],
                documents=[question.question],  # Question text for embedding
                metadatas=[metadata],
                embeddings=[embedding]
            )

            return True

        except Exception as e:
            print(f"Error adding question: {e}")
            return False

    def get_question(self, question_id: str) -> Optional[Question]:
        """Retrieve a question by ID.

        Args:
            question_id: Question ID

        Returns:
            Question object or None if not found
        """
        try:
            result = self.collection.get(ids=[question_id])

            if not result['ids']:
                return None

            # Reconstruct Question object
            metadata = result['metadatas'][0]
            return self._metadata_to_question(
                question_id,
                result['documents'][0],
                metadata
            )

        except Exception as e:
            print(f"Error getting question: {e}")
            return None

    def update_question(self, question_id: str, updates: Dict[str, Any]) -> bool:
        """Update question metadata.

        Args:
            question_id: Question ID
            updates: Dictionary of fields to update

        Returns:
            True if successful, False otherwise
        """
        try:
            # Get existing question
            question = self.get_question(question_id)
            if not question:
                return False

            # Update fields
            for key, value in updates.items():
                if hasattr(question, key):
                    setattr(question, key, value)

            # Re-add question (ChromaDB upsert)
            return self.add_question(question)

        except Exception as e:
            print(f"Error updating question: {e}")
            return False

    def update_rating(
        self,
        question_id: str,
        user_id: str,
        rating: int
    ) -> bool:
        """Update user rating for a question.

        Args:
            question_id: Question ID
            user_id: User ID
            rating: Rating 1-5

        Returns:
            True if successful, False otherwise
        """
        try:
            question = self.get_question(question_id)
            if not question:
                return False

            # Update user_ratings dict
            question.user_ratings[user_id] = rating
            question.usage_count += 1

            # Save
            return self.update_question(question_id, {
                "user_ratings": question.user_ratings,
                "usage_count": question.usage_count
            })

        except Exception as e:
            print(f"Error updating rating: {e}")
            return False

    def search_questions(
        self,
        query_text: Optional[str] = None,
        filters: Optional[Dict[str, Any]] = None,
        n_results: int = 10,
        excluded_ids: Optional[List[str]] = None
    ) -> List[Question]:
        """Search for questions using semantic search and filters.

        Args:
            query_text: Optional query text for semantic search
            filters: Metadata filters (difficulty, category, topic, etc.)
            n_results: Number of results to return
            excluded_ids: Question IDs to exclude

        Returns:
            List of Question objects

        Example:
            >>> questions = client.search_questions(
            ...     query_text="science questions about space",
            ...     filters={"difficulty": "medium", "category": "adults"},
            ...     n_results=5,
            ...     excluded_ids=["q_123", "q_456"]
            ... )
        """
        try:
            # Build where clause
            where_clause = filters or {}

            # Exclude specific IDs
            if excluded_ids:
                where_clause["$and"] = where_clause.get("$and", [])
                for qid in excluded_ids:
                    where_clause["$and"].append({"id": {"$ne": qid}})

            # Query ChromaDB
            if query_text:
                query_embedding = generate_embedding(query_text)
                results = self.collection.query(
                    query_embeddings=[query_embedding],
                    where=where_clause if where_clause else None,
                    n_results=n_results
                )
            else:
                # No semantic search, just filter
                results = self.collection.get(
                    where=where_clause if where_clause else None,
                    limit=n_results
                )

            # Convert to Question objects
            questions = []
            ids = results['ids'][0] if 'ids' in results and results['ids'] else results.get('ids', [])
            documents = results['documents'][0] if 'documents' in results and results['documents'] else results.get('documents', [])
            metadatas = results['metadatas'][0] if 'metadatas' in results and results['metadatas'] else results.get('metadatas', [])

            for i, qid in enumerate(ids):
                question = self._metadata_to_question(
                    qid,
                    documents[i],
                    metadatas[i]
                )
                questions.append(question)

            return questions

        except Exception as e:
            print(f"Error searching questions: {e}")
            return []

    def find_duplicates(
        self,
        question_text: str,
        threshold: float = 0.85
    ) -> List[tuple[Question, float]]:
        """Find potential duplicate questions.

        Args:
            question_text: Question text to check
            threshold: Similarity threshold (default: 0.85)

        Returns:
            List of (Question, similarity_score) tuples above threshold
        """
        try:
            # Generate embedding
            query_embedding = generate_embedding(question_text)

            # Query all questions
            results = self.collection.query(
                query_embeddings=[query_embedding],
                n_results=10  # Check top 10 most similar
            )

            duplicates = []
            if results['ids'] and results['ids'][0]:
                ids = results['ids'][0]
                documents = results['documents'][0]
                metadatas = results['metadatas'][0]
                distances = results['distances'][0] if 'distances' in results else []

                for i, qid in enumerate(ids):
                    # ChromaDB returns distance, convert to similarity
                    # similarity = 1 - distance
                    similarity = 1 - distances[i] if distances else 0.0

                    if similarity >= threshold:
                        question = self._metadata_to_question(
                            qid,
                            documents[i],
                            metadatas[i]
                        )
                        duplicates.append((question, similarity))

            return duplicates

        except Exception as e:
            print(f"Error finding duplicates: {e}")
            return []

    def delete_question(self, question_id: str) -> bool:
        """Delete a question.

        Args:
            question_id: Question ID

        Returns:
            True if successful, False otherwise
        """
        try:
            self.collection.delete(ids=[question_id])
            return True
        except Exception as e:
            print(f"Error deleting question: {e}")
            return False

    def _metadata_to_question(
        self,
        question_id: str,
        question_text: str,
        metadata: Dict[str, Any]
    ) -> Question:
        """Convert ChromaDB metadata back to Question object.

        Args:
            question_id: Question ID
            question_text: Question text
            metadata: Metadata dict from ChromaDB

        Returns:
            Question object
        """
        # Parse JSON fields
        tags = json.loads(metadata.get("tags", "[]"))
        user_ratings = json.loads(metadata.get("user_ratings", "{}"))

        # Parse correct_answer (could be string or list)
        correct_answer_raw = metadata.get("correct_answer", "")
        try:
            correct_answer = json.loads(correct_answer_raw)
        except (json.JSONDecodeError, TypeError):
            correct_answer = correct_answer_raw

        # Optional JSON fields
        possible_answers = None
        if "possible_answers" in metadata:
            possible_answers = json.loads(metadata["possible_answers"])

        alternative_answers = []
        if "alternative_answers" in metadata:
            alternative_answers = json.loads(metadata["alternative_answers"])

        return Question(
            id=question_id,
            question=question_text,
            type=metadata.get("type", "text"),
            possible_answers=possible_answers,
            correct_answer=correct_answer,
            alternative_answers=alternative_answers,
            topic=metadata.get("topic", "General"),
            category=metadata.get("category", "general"),
            difficulty=metadata.get("difficulty", "medium"),
            tags=tags,
            created_at=datetime.fromisoformat(metadata.get("created_at", datetime.now().isoformat())),
            created_by=metadata.get("created_by"),
            source=metadata.get("source", "generated"),
            usage_count=metadata.get("usage_count", 0),
            user_ratings=user_ratings,
            media_url=metadata.get("media_url"),
            media_duration_seconds=metadata.get("media_duration_seconds"),
            explanation=metadata.get("explanation")
        )
