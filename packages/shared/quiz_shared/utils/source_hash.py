"""`source_hash` — the binding between an approved translation and the English
text it was approved against (#168 — batch translation pipeline SK/CS, DD3).

WHY this exists: post-approval English edits are real (rating-round *rephrase*
and *data-fix* verdicts, #167 refreshes of time-sensitive questions, unit
localization rewrites). Without a hash of the source, such an edit leaves an
approved translation of text that no longer exists silently serving, and
nothing in the system can notice. With it, the write path demotes the
translation in the same transaction as the edit (`PgvectorQuestionStore.upsert`)
and `reconcile` acts as the backstop for writers that bypass the store.

The hash covers **exactly** the fields that get translated. `category`,
`difficulty`, `source_url`, embeddings and `review_status` are deliberately
outside it: editing those does not invalidate a translation, and hashing them
would demote good translations on every unrelated admin touch.
"""

from __future__ import annotations

import hashlib
import json
import unicodedata
from typing import Any, Dict, List, Optional, Union

__all__ = ["TRANSLATED_SOURCE_FIELDS", "compute_source_hash", "source_hash_for"]

# The five translated fields, in the order DD3 names them. Order is irrelevant
# to the digest (`sort_keys=True`) but this is the canonical list the runner and
# the store must agree on.
TRANSLATED_SOURCE_FIELDS = (
    "question",
    "possible_answers",
    "correct_answer",
    "alternative_answers",
    "explanation",
)


def _canonical(value: Any) -> Any:
    """Normalize a value so cosmetic churn cannot fake an edit.

    `None` -> `""`, every string `strip()`ed and NFC-normalized, containers
    walked recursively. NFC matters because the same accented character can
    arrive precomposed or decomposed depending on the editor that produced it:
    two byte sequences, one word, and a naive hash would call that an edit.
    """
    if value is None:
        return ""
    if isinstance(value, str):
        return unicodedata.normalize("NFC", value.strip())
    if isinstance(value, dict):
        return {_canonical(k): _canonical(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_canonical(v) for v in value]
    return value


def compute_source_hash(
    *,
    question: Optional[str],
    possible_answers: Optional[Dict[str, str]],
    correct_answer: Union[str, List[str], None],
    alternative_answers: Optional[List[str]],
    explanation: Optional[str],
) -> str:
    """sha256 over a canonical JSON dump of the translated source fields."""
    payload = _canonical(
        {
            "question": question,
            "possible_answers": possible_answers,
            "correct_answer": correct_answer,
            "alternative_answers": alternative_answers,
            "explanation": explanation,
        }
    )
    dumped = json.dumps(
        payload, sort_keys=True, ensure_ascii=False, separators=(",", ":")
    )
    return hashlib.sha256(dumped.encode("utf-8")).hexdigest()


def _field(source: Any, name: str) -> Any:
    """Read one field off either shape the callers hold."""
    if hasattr(source, "keys"):
        return source[name] if name in source.keys() else None
    return getattr(source, name, None)


def source_hash_for(source: Any) -> str:
    """`compute_source_hash` for anything carrying the five fields as
    attributes (a `Question`, an ORM row) or as mapping keys (a DB row, a dict).

    Both shapes occur: the store hashes a `Question`, while the offline runner
    hashes rows it selected straight out of Postgres.
    """
    return compute_source_hash(
        **{name: _field(source, name) for name in TRANSLATED_SOURCE_FIELDS}
    )
