"""Fact sourcing layer for source-grounded question generation."""

from .models import Fact, FactBatch
from .fact_sourcer import FactSourcer

__all__ = ["Fact", "FactBatch", "FactSourcer"]
