---
name: verify-questions
description: Verify question-answer accuracy and populate source URLs/excerpts
allowed-tools: Read, Write, Bash, Glob, Grep, WebSearch, WebFetch, AskUserQuestion
argument-hint: "[path/to/questions.json]"
---

# Verify Quiz Questions

Fact-check question-answer pairs, flag issues, and populate source attribution (URL + excerpt) for each question.

## Instructions

### 1. Parse Arguments

Parse `$ARGUMENTS` for an optional file path:
- Default: `apps/quiz-agent/questions_export.json`
- Accept any JSON file path

### 2. Load Questions

Read the JSON file. Handle both formats:
- **Flat array:** `[{...}, {...}]`
- **Batch wrapper:** `{"questions": [{...}, ...]}`

Extract the list of question objects. Each should have at minimum: `id`, `question`, `correct_answer`.

Report: "Loaded N questions from <path>"

### 3. Verify Questions in Batches

Process questions in batches of ~15 for manageable reasoning. For EACH question:

#### a) Independent Verification
Without looking at the stored answer first, reason about what the correct answer should be. Then compare with the stored `correct_answer`.

#### b) Flag Issues
Check for:
- **Wrong answer:** Your independent answer differs from stored answer
- **Myth/misconception:** The "correct" answer is a common myth
- **Ambiguity:** Multiple valid answers exist but only one is accepted (check `alternative_answers` too)
- **Misleading premise:** The question contains a false assumption
- **Missing alternatives:** Common valid phrasings not in `alternative_answers`
- **Outdated:** Answer may have changed (e.g., population figures, records, political facts)

#### c) Find Source
Use `WebSearch` to find a reliable source URL for the answer. Prefer:
1. Wikipedia articles
2. Encyclopaedia Britannica
3. Official/governmental sources
4. Reputable news outlets
5. Academic/educational sites

Extract a 1-2 sentence excerpt from the source that confirms the answer.

#### d) Assign Verdict
- **correct** — Answer verified, no issues
- **needs_fix** — Clear error that should be corrected (include suggested fix)
- **needs_review** — Ambiguous or uncertain, human should decide
- **incorrect** — Answer is definitively wrong

### 4. Save Report

Save to `data/verification/report_YYYY-MM-DD.json`:

```json
{
  "metadata": {
    "verified_at": "<ISO timestamp>",
    "source_file": "<path>",
    "total_questions": 69,
    "verdicts": {
      "correct": 60,
      "needs_fix": 3,
      "needs_review": 4,
      "incorrect": 2
    }
  },
  "questions": [
    {
      "id": "q_abc123",
      "question": "Question text?",
      "stored_answer": "Paris",
      "verdict": "correct",
      "notes": "Verified. Paris is the capital of France.",
      "suggested_fix": null,
      "source_url": "https://en.wikipedia.org/wiki/Paris",
      "source_excerpt": "Paris is the capital and largest city of France."
    }
  ]
}
```

### 5. Save Enriched Questions

Save to `data/verification/enriched_YYYY-MM-DD.json` — the original questions with `source_url` and `source_excerpt` populated:

```json
[
  {
    "id": "q_abc123",
    "question": "Question text?",
    "correct_answer": "Paris",
    "source_url": "https://en.wikipedia.org/wiki/Paris",
    "source_excerpt": "Paris is the capital and largest city of France.",
    ...all other original fields preserved...
  }
]
```

Only populate source fields for questions with verdict `correct` or `needs_review`. Leave source fields null for `incorrect` and `needs_fix` questions (they need manual attention first).

### 6. Present Summary

Print a console summary:

```
Verification Complete
=====================
Total: 69 questions
  correct:      60 (87%)
  needs_fix:     3 (4%)
  needs_review:  4 (6%)
  incorrect:     2 (3%)

Sources found: 65/69 (94%)

Flagged Questions:
  #  ID           Verdict       Issue
  1  q_abc123     needs_fix     Stored answer "X" but correct is "Y"
  2  q_def456     incorrect     Premise is a myth: ...
  3  q_ghi789     needs_review  Multiple valid answers: ...

Reports saved to:
  data/verification/report_YYYY-MM-DD.json
  data/verification/enriched_YYYY-MM-DD.json
```

### 7. Offer Source Backfill

Ask the user:
> "Would you like to backfill source URLs into ChromaDB? This will update 65 questions with source attribution data."

If yes, run:
```bash
.venv/bin/python scripts/backfill_sources.py data/verification/enriched_YYYY-MM-DD.json
```

## Important

- **Accuracy is critical.** When uncertain, mark as `needs_review` rather than `correct`.
- **Don't "fix" questions silently.** Flag issues for human review.
- **Source quality matters.** Prefer authoritative sources. Skip rather than use unreliable sources.
- **Preserve original data.** The enriched file should keep ALL original fields intact, only adding/updating `source_url` and `source_excerpt`.
