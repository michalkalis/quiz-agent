---
name: score-questions
description: Score quiz questions on 5 quality dimensions and recommend approve/revise/reject
allowed-tools: Read, Write, Bash, Glob, Grep, AskUserQuestion
model: sonnet
argument-hint: "[path/to/questions.json] [--save-to-db]"
---

# Score Quiz Questions

Evaluate quiz questions on 5 engagement dimensions tailored to the driving quiz experience. Produce scored output with approve/revise/reject recommendations.

## Instructions

### 1. Parse Arguments

Parse `$ARGUMENTS` for:
- **file path** (optional): Path to a questions JSON file. If not provided, find the latest:
  ```bash
  ls -t data/generated/claude_batch_*.json 2>/dev/null | head -1
  ```
  If no files found, ask the user for a path.
- **--save-to-db** (optional flag): Persist scores to the `model_scores` SQLite table.

### 2. Load Questions

Read the JSON file. Handle both formats:
- **Batch wrapper:** `{"questions": [{...}, ...]}`
- **Flat array:** `[{...}, {...}]`

Each question should have at minimum: `question`, `correct_answer`. Optionally: `id`, `topic`, `difficulty`, `category`.

Report: "Loaded N questions from <path>"

### 3. Read Scoring Calibration

Before scoring, read `apps/question-generator/app/scoring/multi_model_scorer.py` to calibrate against the same rubric used by the automated multi-model scoring system. This ensures consistency between Claude Code scoring and API-based scoring.

### 4. Score Each Question

For EACH question, evaluate on these 5 dimensions (1-10 scale):

| Dimension | What to evaluate | Low (1-3) | High (8-10) |
|-----------|-----------------|-----------|-------------|
| **Conversation Spark** | Would this generate discussion at a quiz table? Invite debate, speculation, storytelling? | Generic fact, no discussion value | "Wait, really?!" — sparks follow-up questions and stories |
| **Surprise/Delight** | Does the answer create a "Wow!" moment? Unexpected twist? Delightful fact? | Predictable, boring answer | Genuinely surprising, makes you smile or gasp |
| **Tellability** | Would you share this at a party? Memorable and repeatable? | Forgettable, hard to retell | "You'll never guess..." — begs to be shared |
| **Driving Friendliness** | Safe cognitive load while driving? No visual aids needed? Reasonable mental processing? | Requires mental math, visualization, long lists, or reading | Simple to process audibly, clear answer space |
| **Clever Framing** | Creative question structure? Avoids boring formats? | "What is...", "Who wrote...", plain factual | Narrative framing, unexpected angle, makes you think |

For each question, provide 1-2 sentences of reasoning explaining the scores.

**Overall Score**: Average of all 5 dimensions, rounded to 1 decimal.

**Recommendation** based on overall score:
- **approve** (>= 8.0) — Ready for production
- **revise** (6.0–7.9) — Has potential, include specific improvement suggestions
- **reject** (< 6.0) — Not suitable, explain why

### 5. Save Scored Output

Create `data/scored/` directory if it doesn't exist. Save to `data/scored/scored_YYYY-MM-DD.json`:

```json
{
  "metadata": {
    "scored_at": "<ISO timestamp>",
    "source_file": "<path>",
    "scored_by": "claude-opus-4-6",
    "total_questions": 10,
    "recommendations": {
      "approve": 7,
      "revise": 2,
      "reject": 1
    },
    "avg_overall_score": 8.1
  },
  "questions": [
    {
      "id": "q_abc123",
      "question": "Question text?",
      "correct_answer": "Answer",
      "difficulty": "medium",
      "topic": "Science",
      "category": "adults",
      "scores": {
        "conversation_spark": 8,
        "surprise_delight": 9,
        "tellability": 8,
        "driving_friendliness": 7,
        "clever_framing": 9
      },
      "overall_score": 8.2,
      "recommendation": "approve",
      "reasoning": "Strong surprise factor with the unexpected connection..."
    }
  ]
}
```

If the file already exists (multiple runs on same day), append a counter: `scored_YYYY-MM-DD_2.json`.

### 6. Present Ranked Summary

Sort questions by overall score (descending) and display:

```
Scoring Complete
================
Source: data/generated/claude_batch_016.json
Scored by: claude-opus-4-6

  #  Score  Rec      Diff    Topic         CS  S/D  Tell DrF  CF   Question (truncated)
  1   9.2   approve  hard    Nature        9   10   9    8    10   Which creature can...
  2   8.8   approve  medium  History       9   9    8    9    9    What board game...
  3   7.4   revise   easy    Science       7   8    7    8    7    How many elements...
 10   5.2   reject   medium  Geography     5   4    6    6    5    What is the capital...

Summary:  approve: 7  |  revise: 2  |  reject: 1  |  avg: 8.1
Saved to: data/scored/scored_2026-04-15.json
```

Legend: CS=Conversation Spark, S/D=Surprise/Delight, Tell=Tellability, DrF=Driving Friendliness, CF=Clever Framing

### 7. Optional: Save to Database

If `--save-to-db` was passed:

1. Check if the question-generator service is running:
   ```bash
   curl -s -o /dev/null -w '%{http_code}' http://localhost:8003/api/v1/health
   ```

2. If running, save via Python:
   ```bash
   cd /Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent && .venv/bin/python -c "
   import json, sys
   sys.path.insert(0, 'packages/shared')
   from quiz_shared.database.sql_client import SQLClient
   db = SQLClient()
   with open('data/scored/scored_YYYY-MM-DD.json') as f:
       data = json.load(f)
   for q in data['questions']:
       db.add_model_score(
           question_id=q['id'],
           scored_by='claude-opus-4-6',
           scores=q['scores'],
           overall_score=q['overall_score']
       )
   print(f'Saved {len(data[\"questions\"])} scores to model_scores table')
   "
   ```

3. If not running: "To save scores to DB, start the service with `/start-local questions` and re-run with `--save-to-db`."

### 8. Suggest Next Steps

After presenting results:
- For `approve` questions: "Run `/verify-questions <file>` to fact-check before importing to ChromaDB."
- For `revise` questions: "Consider regenerating with `/generate-questions` focusing on weak dimensions."
- For `reject` questions: "These should be dropped or completely reworked."

## Important

- **Be honest and critical.** Do not inflate scores. A truly average question should score 5-6, not 7-8. Calibrate: the best questions you've ever seen are 9-10, average bar trivia is 5-6.
- **Driving Friendliness is about cognitive load:** Long questions with multiple clauses score low. Questions requiring mental math, visualization, or lists score low. Questions with clear, short audio delivery score high.
- **Conversation Spark rewards discussion:** Questions where people say "Wait, really?" or want to debate the answer. Not just interesting facts, but ones that invite follow-up.
- **Missing `id` field:** Generate a temporary ID like `q_scored_001` for output.
- **Large batches (20+):** Score them all but maintain consistency. If you notice score drift, re-calibrate by reviewing your first few scores.
