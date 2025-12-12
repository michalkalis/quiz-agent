"""SQL client for ratings and session persistence."""

from sqlalchemy import create_engine, Column, String, Integer, Float, Boolean, DateTime, Text
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker, Session
from datetime import datetime
from typing import List, Optional

from ..models.rating import QuestionRating

Base = declarative_base()


class RatingDB(Base):
    """SQLAlchemy model for question ratings."""
    __tablename__ = "question_ratings"

    id = Column(String, primary_key=True)
    question_id = Column(String, nullable=False, index=True)
    session_id = Column(String, nullable=False, index=True)
    user_id = Column(String, nullable=True)
    rating = Column(Integer, nullable=False)
    feedback = Column(Text, nullable=True)
    was_correct = Column(Boolean, nullable=False)
    user_answer = Column(String, nullable=False)
    difficulty_at_time = Column(String, nullable=False)
    created_at = Column(DateTime, default=datetime.now, index=True)


class SQLClient:
    """Client for SQL database operations (ratings, sessions).

    Supports SQLite for development and PostgreSQL for production.
    """

    def __init__(self, database_url: str = "sqlite:///./quiz_data.db"):
        """Initialize SQL client.

        Args:
            database_url: Database connection URL
                - SQLite: "sqlite:///./quiz_data.db"
                - PostgreSQL: "postgresql://user:pass@localhost/dbname"
        """
        self.engine = create_engine(database_url, echo=False)
        Base.metadata.create_all(self.engine)
        self.SessionLocal = sessionmaker(bind=self.engine)

    def _get_session(self) -> Session:
        """Get database session."""
        return self.SessionLocal()

    def add_rating(self, rating: QuestionRating) -> bool:
        """Add a question rating.

        Args:
            rating: QuestionRating object

        Returns:
            True if successful, False otherwise
        """
        try:
            session = self._get_session()

            db_rating = RatingDB(
                id=rating.id,
                question_id=rating.question_id,
                session_id=rating.session_id,
                user_id=rating.user_id,
                rating=rating.rating,
                feedback=rating.feedback,
                was_correct=rating.was_correct,
                user_answer=rating.user_answer,
                difficulty_at_time=rating.difficulty_at_time,
                created_at=rating.created_at
            )

            session.add(db_rating)
            session.commit()
            session.close()

            return True

        except Exception as e:
            print(f"Error adding rating: {e}")
            if session:
                session.rollback()
                session.close()
            return False

    def get_ratings_by_question(self, question_id: str) -> List[QuestionRating]:
        """Get all ratings for a question.

        Args:
            question_id: Question ID

        Returns:
            List of QuestionRating objects
        """
        try:
            session = self._get_session()
            ratings = session.query(RatingDB).filter(
                RatingDB.question_id == question_id
            ).all()

            result = [self._db_to_rating(r) for r in ratings]
            session.close()

            return result

        except Exception as e:
            print(f"Error getting ratings: {e}")
            if session:
                session.close()
            return []

    def get_ratings_by_session(self, session_id: str) -> List[QuestionRating]:
        """Get all ratings for a quiz session.

        Args:
            session_id: Session ID

        Returns:
            List of QuestionRating objects
        """
        try:
            session = self._get_session()
            ratings = session.query(RatingDB).filter(
                RatingDB.session_id == session_id
            ).all()

            result = [self._db_to_rating(r) for r in ratings]
            session.close()

            return result

        except Exception as e:
            print(f"Error getting ratings: {e}")
            if session:
                session.close()
            return []

    def get_avg_rating(self, question_id: str) -> Optional[float]:
        """Get average rating for a question.

        Args:
            question_id: Question ID

        Returns:
            Average rating or None if no ratings
        """
        try:
            session = self._get_session()
            ratings = session.query(RatingDB.rating).filter(
                RatingDB.question_id == question_id
            ).all()

            session.close()

            if not ratings:
                return None

            return sum(r[0] for r in ratings) / len(ratings)

        except Exception as e:
            print(f"Error getting avg rating: {e}")
            if session:
                session.close()
            return None

    def get_low_rated_questions(
        self,
        threshold: float = 2.5,
        min_ratings: int = 3
    ) -> List[tuple[str, float]]:
        """Get questions with low average ratings.

        Args:
            threshold: Rating threshold (default: 2.5)
            min_ratings: Minimum number of ratings required

        Returns:
            List of (question_id, avg_rating) tuples
        """
        try:
            session = self._get_session()

            # Query with grouping
            from sqlalchemy import func
            results = session.query(
                RatingDB.question_id,
                func.avg(RatingDB.rating).label('avg_rating'),
                func.count(RatingDB.id).label('rating_count')
            ).group_by(
                RatingDB.question_id
            ).having(
                func.count(RatingDB.id) >= min_ratings
            ).having(
                func.avg(RatingDB.rating) < threshold
            ).all()

            session.close()

            return [(r.question_id, r.avg_rating) for r in results]

        except Exception as e:
            print(f"Error getting low rated questions: {e}")
            if session:
                session.close()
            return []

    def _db_to_rating(self, db_rating: RatingDB) -> QuestionRating:
        """Convert database model to Pydantic model.

        Args:
            db_rating: RatingDB object

        Returns:
            QuestionRating object
        """
        return QuestionRating(
            id=db_rating.id,
            question_id=db_rating.question_id,
            session_id=db_rating.session_id,
            user_id=db_rating.user_id,
            rating=db_rating.rating,
            feedback=db_rating.feedback,
            was_correct=db_rating.was_correct,
            user_answer=db_rating.user_answer,
            difficulty_at_time=db_rating.difficulty_at_time,
            created_at=db_rating.created_at
        )
