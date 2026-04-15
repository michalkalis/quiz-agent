---
name: verify-questions
description: Verify question-answer accuracy and populate source URLs/excerpts
allowed-tools: Read, Write, Bash, Glob, Grep, WebSearch, WebFetch, AskUserQuestion
model: sonnet
argument-hint: "[path/to/questions.json]"
---

# Verify Quiz Questions

Fact-check question-answer pairs using the FactVerifier service (Tavily + Gemini Flash), flag issues, and populate source attribution (URL + excerpt) for each question.

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

### 3. Batch Verify via FactVerifier Service

#### 3a. Check Service Availability

```bash
curl -s -o /dev/null -w '%{http_code}' http://localhost:8003/api/v1/health
```

If NOT running (non-200 response):
- Inform the user: "FactVerifier service is not running at localhost:8003. Start it with `/start-local questions`."
- Ask: "Would you like to fall back to manual web search verification? (slower, but doesn't require the service)"
- If yes → use the **Fallback: Manual Verification** method at the bottom of this document.
- If no → stop.

#### 3b. Send Batch Request

For large question sets (25+), split into sub-batches of 25 to avoid timeout.

Use this pattern to extract questions and POST:

```bash
.venv/bin/python -c "
import json, urllib.request, sys
with open('<FILE_PATH>') as f:
    data = json.load(f)
qs = data.get('questions', data) if isinstance(data, dict) else data
payload = {'questions': [{'question': q['question'], 'correct_answer': str(q['correct_answer']), 'id': q.get('id', f'q_{i}'), 'topic': q.get('topic', '')} for i, q in enumerate(qs)]}
req = urllib.request.Request('http://localhost:8003/api/v1/verify/batch', data=json.dumps(payload).encode(), headers={'Content-Type': 'application/json'})
resp = urllib.request.urlopen(req, timeout=300)
print(resp.read().decode())
"
```

#### 3c. Parse Response & Map Verdicts

The FactVerifier returns results with these fields per question:
- `verification.verdict`: `verified | likely_correct | uncertain | likely_wrong | wrong`
- `verification.confidence`: 0.0-1.0
- `verification.sources`: array of `{url, excerpt, agrees_with_answer, relevance_score}`
- `verification.alternative_answers`: array of strings
- `verification.notes`: explanation

Map FactVerifier verdicts to report verdicts:

| FactVerifier | Report Verdict | Action |
|---|---|---|
| `verified` | `correct` | Use best source for attribution |
| `likely_correct` | `correct` | Note: "Likely correct (confidence: X%)" |
| `uncertain` | `needs_review` | Flag for deep-dive in step 3d |
| `likely_wrong` | `needs_fix` | Flag for deep-dive, include alternatives |
| `wrong` | `incorrect` | Flag for deep-dive, include alternatives |

#### 3d. Sanity Check & Deep-Dive Flagged Questions

For ALL questions, do a quick sanity check:
- Does the verdict make sense given what you know?
- If you disagree with a FactVerifier verdict, override it and note "Claude override: [reason]"

For questions with verdict `needs_fix`, `incorrect`, or `needs_review`:
- Use `WebSearch` to independently verify (second opinion)
- Check if the FactVerifier's `alternative_answers` are correct
- Provide a specific `suggested_fix` if the answer is wrong
- This uses manual verification but ONLY for flagged questions (not all)

#### 3e. Extract Source Attribution

For each question with verdict `correct` or `needs_review`:
- From the FactVerifier's `sources` array, find the source with the highest `relevance_score` where `agrees_with_answer` is `true`
- Set `source_url` = that source's URL
- Set `source_excerpt` = that source's excerpt (trim to 2 sentences if longer)
- If no agreeing source found, leave source fields null

### 4. Save Report

Save to `data/verification/report_YYYY-MM-DD.json`:

```json
{
  "metadata": {
    "verified_at": "<ISO timestamp>",
    "source_file": "<path>",
    "verification_method": "fact_verifier_service",
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
      "fact_verifier_verdict": "verified",
      "fact_verifier_confidence": 0.95,
      "notes": "Verified by FactVerifier. 4/5 sources confirm.",
      "suggested_fix": null,
      "source_url": "https://en.wikipedia.org/wiki/Paris",
      "source_excerpt": "Paris is the capital and largest city of France."
    }
  ]
}
```

### 5. Save Enriched Questions

Save to `data/verification/enriched_YYYY-MM-DD.json` — the original questions with `source_url` and `source_excerpt` populated.

Only populate source fields for questions with verdict `correct` or `needs_review`. Leave source fields null for `incorrect` and `needs_fix` questions (they need attention first).

### 6. Present Summary

```
Verification Complete (via FactVerifier service)
=================================================
Total: 69 questions
  correct:      60 (87%)
  needs_fix:     3 (4%)
  needs_review:  4 (6%)
  incorrect:     2 (3%)

Sources found: 65/69 (94%)
Claude overrides: 2

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
> "Would you like to backfill source URLs into ChromaDB? This will update N questions with source attribution data."

If yes, run:
```bash
.venv/bin/python scripts/backfill_sources.py data/verification/enriched_YYYY-MM-DD.json
```

## Important

- **Accuracy is critical.** When uncertain, mark as `needs_review` rather than `correct`.
- **Don't "fix" questions silently.** Flag issues for human review.
- **Source quality matters.** Prefer authoritative sources. Skip rather than use unreliable sources.
- **Preserve original data.** The enriched file should keep ALL original fields intact, only adding/updating `source_url` and `source_excerpt`.

---

## Fallback: Manual Web Search Verification

Use this method ONLY when the FactVerifier service is not available and the user opts in.

Process questions in batches of ~15. For EACH question:

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
Use `WebSearch` to find a reliable source URL. Prefer: Wikipedia, Britannica, official/governmental sources, reputable news, academic sites.

Extract a 1-2 sentence excerpt from the source that confirms the answer.

#### d) Assign Verdict
- **correct** — Answer verified, no issues
- **needs_fix** — Clear error that should be corrected (include suggested fix)
- **needs_review** — Ambiguous or uncertain, human should decide
- **incorrect** — Answer is definitively wrong

Then continue from step 4 (Save Report) using `"verification_method": "manual_web_search"`.
