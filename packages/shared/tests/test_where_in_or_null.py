"""`$in_or_null` filter: legacy NULL-language rows are English and must match.

A plain `IN ('en','sk')` drops NULL rows (SQL three-valued logic), which would
silently hide the whole pre-language corpus (native sk/cs corpus, founder
2026-10-08).
"""

from quiz_shared.database.pgvector_client import _build_where


def test_in_or_null_keeps_null_language_rows():
    (clause,) = _build_where({"language": {"$in_or_null": ["en", "sk"]}})
    sql = str(clause.compile(compile_kwargs={"literal_binds": True}))
    assert "language IN ('en', 'sk')" in sql
    assert "language IS NULL" in sql
    assert " OR " in sql


def test_or_branches_are_anded_internally():
    # The native-corpus gate: (English row AND no English wordplay) OR (row in
    # the session's own language). Losing the inner AND would let English
    # wordplay leak into a Slovak session.
    (clause,) = _build_where(
        {
            "$or": [
                {"language": {"$in_or_null": ["en"]}, "language_dependent": False},
                {"language": "sk"},
            ]
        }
    )
    sql = " ".join(str(clause.compile(compile_kwargs={"literal_binds": True})).split())
    assert "language IS NULL" in sql
    assert "language_dependent = false" in sql
    assert "language = 'sk'" in sql
    assert sql.count(" AND ") >= 1 and " OR " in sql
