"""SQLAlchemy ORM tables for quiz-pack-api (issue #33 Task 1.5).

The four core tables — `questions`, `generation_orders`, `generation_jobs`,
`question_packs` — plus the `append_step` JSONB-array-append helper.

Importing this package side-effects registration of every model on
``Base.metadata``; ``alembic/env.py`` and the test fixture rely on that.
"""

from .job import JOB_STATUSES, GenerationJob, append_step
from .order import ORDER_STATUSES, GenerationOrder
from .pack import QuestionPack
from .question import (
    EMBEDDING_DIM,
    REVIEW_STATUSES,
    QuestionRow,
    question_to_row,
    row_to_question,
)

__all__ = [
    "EMBEDDING_DIM",
    "GenerationJob",
    "GenerationOrder",
    "JOB_STATUSES",
    "ORDER_STATUSES",
    "QuestionPack",
    "QuestionRow",
    "REVIEW_STATUSES",
    "append_step",
    "question_to_row",
    "row_to_question",
]
