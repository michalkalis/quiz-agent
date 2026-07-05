"""Database clients for quiz system.

`ChromaDBClient` is exported lazily (PEP 562 `__getattr__`): `import chromadb`
drags in ~100MB+ of transitive deps (onnxruntime, grpc, opentelemetry, …) that
OOM-killed the 256MB quiz-pack-api machines, whose live pipeline is pure
pgvector (2026-07-05 incident). Consumers that only need pgvector/pending/SQL
stores must not pay for chromadb at import time.
"""

from .pending_store import InMemoryPendingStore, PendingStore, SQLitePendingStore
from .pgvector_client import PgvectorQuestionStore
from .question_store import ChromaDBQuestionStore, QuestionStore
from .sql_client import SQLClient


def __getattr__(name: str):
    if name == "ChromaDBClient":
        from .chroma_client import ChromaDBClient

        return ChromaDBClient
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


__all__ = [
    "ChromaDBClient",
    "ChromaDBQuestionStore",
    "InMemoryPendingStore",
    "PendingStore",
    "PgvectorQuestionStore",
    "QuestionStore",
    "SQLClient",
    "SQLitePendingStore",
]
