"""The #168 batch translation runner, split by subcommand family so each
module stays inside the repo's ~300-line limit (CLI: ``scripts/translate_corpus.py``).

- ``workset``   — what to translate (eligibility, resume state) + the job JSONL
- ``translate`` — ``submit`` / ``ingest`` (DB rows written only at ingest, DD7)
- ``verify``    — the four-stage gate, review export, corrections, glossary
- ``report``    — ``report --coverage`` bars and ``reconcile`` (DD1/DD4)
"""
