"""`$gt` / `$lt` filters (#199 — question stock check).

"Fresh" entertainment stock means boosted past a horizon but not forever
(permanent boosts sit at 9999-01-01), which needs a lower AND an upper bound on
the same column. A bound that is dropped or ORed silently counts permanent
boosts as fresh and hides the shortage the check exists to catch.
"""

from datetime import UTC, datetime

import pytest
from quiz_shared.database.pgvector_client import _build_where

LOW = datetime(2026, 10, 24, tzinfo=UTC)
HIGH = datetime(9000, 1, 1, tzinfo=UTC)


def _sql(clause) -> str:
    return " ".join(str(clause.compile(compile_kwargs={"literal_binds": True})).split())


def test_gt_and_lt_become_two_anded_bounds_on_one_column():
    clauses = _build_where({"boost_until": {"$gt": LOW, "$lt": HIGH}})

    # Two separate clauses are ANDed by the caller; a single OR would let a
    # permanent boost (> LOW) through.
    assert len(clauses) == 2
    sql = [_sql(c) for c in clauses]
    assert any("boost_until > '2026-10-24" in s for s in sql)
    assert any("boost_until < '9000-01-01" in s for s in sql)
    assert not any(" OR " in s for s in sql)


@pytest.mark.parametrize("op, symbol", [("$gt", ">"), ("$lt", "<")])
def test_a_single_bound_is_enough(op, symbol):
    (clause,) = _build_where({"boost_until": {op: LOW}})
    assert f"boost_until {symbol} '2026-10-24" in _sql(clause)


def test_strict_not_inclusive():
    # "Still fresh in 14 days" must not count a row expiring exactly then.
    (clause,) = _build_where({"boost_until": {"$gt": LOW}})
    assert ">=" not in _sql(clause)


def test_unsupported_operator_beside_a_bound_fails_loud():
    # Dropping the unknown operator would widen the count with no signal.
    with pytest.raises(ValueError, match=r"\$nope"):
        _build_where({"boost_until": {"$gt": LOW, "$nope": 1}})


def test_unknown_column_still_fails_loud():
    with pytest.raises(ValueError, match="Unknown filter key"):
        _build_where({"not_a_column": {"$gt": 1}})
