"""ChromaDB client for question storage with RAG capabilities."""

import chromadb
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
        # Use PersistentClient for proper disk persistence
        self.client = chromadb.PersistentClient(
            path=persist_directory
        )
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
                "review_status": question.review_status,
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

            # Review workflow fields
            if question.reviewed_by:
                metadata["reviewed_by"] = question.reviewed_by
            if question.reviewed_at:
                metadata["reviewed_at"] = question.reviewed_at.isoformat()
            if question.review_notes:
                metadata["review_notes"] = question.review_notes
            if question.quality_ratings:
                metadata["quality_ratings"] = json.dumps(question.quality_ratings)
            if question.generation_metadata:
                metadata["generation_metadata"] = json.dumps(question.generation_metadata)

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

    def count_questions(self, filters: Optional[Dict[str, Any]] = None) -> int:
        """Count questions in the database, optionally with filters.

        Args:
            filters: Optional metadata filters

        Returns:
            Number of questions matching filters (or total if no filters)
        """
        try:
            if filters:
                # Build where clause similar to search_questions
                filters_dict = filters or {}
                top_level_conditions = {}
                operators = {}
                for key, value in filters_dict.items():
                    if key.startswith("$"):
                        operators[key] = value
                    else:
                        top_level_conditions[key] = value
                
                needs_and = len(top_level_conditions) > 1
                if needs_and:
                    where_clause = {"$and": []}
                    for key, value in top_level_conditions.items():
                        where_clause["$and"].append({key: value})
                    where_clause.update(operators)
                elif len(top_level_conditions) == 1:
                    where_clause = top_level_conditions.copy()
                    where_clause.update(operators)
                else:
                    where_clause = operators if operators else None
                
                results = self.collection.get(where=where_clause if where_clause else None)
            else:
                results = self.collection.get()
            
            ids = results.get('ids', [])
            return len(ids) if ids else 0
        except Exception as e:
            print(f"Error counting questions: {e}")
            return 0

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
            # ChromaDB requires all conditions to be wrapped in a single operator when multiple conditions exist
            filters_dict = filters or {}
            
            # Separate top-level conditions from operators
            top_level_conditions = {}
            operators = {}
            for key, value in filters_dict.items():
                if key.startswith("$"):
                    operators[key] = value
                else:
                    top_level_conditions[key] = value
            
            # Build where clause
            # ChromaDB requires all conditions to be wrapped in a single operator when multiple conditions exist
            # NOTE: excluded_ids cannot be filtered via where clause because ChromaDB's where only works on metadata fields
            # The question ID is the primary ID, not a metadata field, so we filter excluded_ids in Python after retrieval
            needs_and = len(top_level_conditions) > 1

            if needs_and:
                where_clause = {"$and": []}
                # Add all top-level conditions
                for key, value in top_level_conditions.items():
                    where_clause["$and"].append({key: value})
                # Merge in any existing operators (shouldn't happen, but handle it)
                where_clause.update(operators)
            elif len(top_level_conditions) == 1:
                # Single condition, use as-is
                where_clause = top_level_conditions.copy()
                where_clause.update(operators)
            else:
                # No filters or only operators
                where_clause = operators if operators else None

            # Debug: print where clause for troubleshooting
            if where_clause:
                print(f"DEBUG: ChromaDB where clause: {where_clause}")

            # Calculate how many results to fetch from ChromaDB
            # If we have excluded_ids, fetch more to account for filtering
            fetch_count = n_results
            if excluded_ids and len(excluded_ids) > 0:
                # Fetch extra to compensate for excluded IDs
                fetch_count = n_results + len(excluded_ids)

            # Query ChromaDB
            try:
                if query_text:
                    query_embedding = generate_embedding(query_text)
                    results = self.collection.query(
                        query_embeddings=[query_embedding],
                        where=where_clause if where_clause else None,
                        n_results=fetch_count
                    )
                else:
                    # No semantic search, just filter
                    results = self.collection.get(
                        where=where_clause if where_clause else None,
                        limit=fetch_count
                    )
            except Exception as query_error:
                print(f"ERROR: ChromaDB query failed with where_clause: {where_clause}")
                print(f"ERROR: Query error: {query_error}")
                import traceback
                traceback.print_exc()
                raise

            # Convert to Question objects
            questions = []
            # Handle different result structures:
            # - query() returns: {'ids': [[...]], 'documents': [[...]]} (nested)
            # - get() returns: {'ids': [...], 'documents': [...]} (flat)
            if 'ids' in results and results['ids']:
                # Check if nested (query) or flat (get)
                if isinstance(results['ids'][0], list):
                    # Nested structure from query()
                    ids = results['ids'][0]
                    documents = results['documents'][0]
                    metadatas = results['metadatas'][0]
                else:
                    # Flat structure from get()
                    ids = results['ids']
                    documents = results['documents']
                    metadatas = results['metadatas']
            else:
                ids = []
                documents = []
                metadatas = []

            for i, qid in enumerate(ids):
                # Filter out excluded IDs (must be done in Python since ChromaDB where clause doesn't support ID filtering)
                if excluded_ids and qid in excluded_ids:
                    continue

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

    def update_question_obj(self, question: Question) -> bool:
        """Update a question object in database.

        Args:
            question: Complete Question object with updates

        Returns:
            True if successful, False otherwise
        """
        try:
            # Re-add question (ChromaDB upsert)
            return self.add_question(question)
        except Exception as e:
            print(f"Error updating question object: {e}")
            return False

    def get_all_questions(self, limit: int = 1000) -> List[Question]:
        """Get all questions from database.

        Args:
            limit: Max number of questions to return

        Returns:
            List of all Question objects
        """
        try:
            results = self.collection.get(limit=limit)

            questions = []
            if 'ids' in results and results['ids']:
                ids = results['ids']
                documents = results['documents']
                metadatas = results['metadatas']

                for i, qid in enumerate(ids):
                    question = self._metadata_to_question(
                        qid,
                        documents[i],
                        metadatas[i]
                    )
                    questions.append(question)

            return questions

        except Exception as e:
            print(f"Error getting all questions: {e}")
            return []

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

        # Ensure correct_answer is string or list (ChromaDB might return int)
        if not isinstance(correct_answer, (str, list)):
            correct_answer = str(correct_answer)

        # Optional JSON fields
        possible_answers = None
        if "possible_answers" in metadata:
            possible_answers = json.loads(metadata["possible_answers"])

        alternative_answers = []
        if "alternative_answers" in metadata:
            alternative_answers = json.loads(metadata["alternative_answers"])

        # Parse review workflow fields
        quality_ratings = None
        if "quality_ratings" in metadata:
            quality_ratings = json.loads(metadata["quality_ratings"])

        generation_metadata = None
        if "generation_metadata" in metadata:
            generation_metadata = json.loads(metadata["generation_metadata"])

        reviewed_at = None
        if "reviewed_at" in metadata:
            reviewed_at = datetime.fromisoformat(metadata["reviewed_at"])

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
            explanation=metadata.get("explanation"),
            review_status=metadata.get("review_status", "pending_review"),
            reviewed_by=metadata.get("reviewed_by"),
            reviewed_at=reviewed_at,
            review_notes=metadata.get("review_notes"),
            quality_ratings=quality_ratings,
            generation_metadata=generation_metadata
        )
