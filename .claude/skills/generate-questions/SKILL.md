---
name: generate-questions
description: Generate high-quality quiz questions using Claude and save for review
allowed-tools: Read, Write, Bash, Glob, Grep, AskUserQuestion
argument-hint: "[count] [difficulty] [topics]"
---

# Generate Quiz Questions

Generate high-quality pub quiz questions directly in this Claude Code session, following the project's established quality criteria.

## Instructions

### 1. Parse Arguments

Parse `$ARGUMENTS` for optional parameters (all have defaults):

| Param | Default | Examples |
|-------|---------|---------|
| count | `10` | `15`, `20`, `5` |
| difficulty | `mixed` | `easy`, `medium`, `hard`, `mixed` |
| topics | broad mix | `"science,history"`, `"nature"` |

Examples of `$ARGUMENTS`:
- `` (empty) → 10 mixed questions, broad topics
- `10 hard science` → 10 hard science questions
- `5 medium "history,nature"` → 5 medium questions on history and nature
- `20` → 20 mixed questions, broad topics

### 2. Read Quality Guidelines

Before generating, read these files for quality criteria:
- `apps/question-generator/prompts/question_generation_v2_cot.md` — Pattern Library, Boring Detector, Constitutional Principles
- `apps/question-generator/prompts/question_critique.md` — 6-dimension scoring rubric

### 3. Generate Questions

Follow the v2_cot prompt's structured process for EACH question:

**Step 1: REASONING** — Pick a pattern from the Pattern Library (Surprising Connection, Hidden Property, Wordplay Revelation, Scale Surprise, Historical Quirk, Biological Oddity). Think about why it's interesting and check the Boring Detector.

**Step 2: GENERATE** — Write the question using that pattern.

**Step 3: SELF-CRITIQUE** — Rate honestly on 6 dimensions (1-10):
- Surprise Factor — "aha!" moment?
- Universal Appeal — works internationally? Not language-dependent?
- Clever Framing — avoids boring "What is..." format?
- Educational Value — teaches something interesting?
- Clarity — unambiguous wording?
- Factual Accuracy — verifiably correct?

**Step 4: DECISION** — Keep if score >= 8.0, regenerate if below.

### Constitutional Principles (MUST follow)

1. **Delight over Memorization** — Joy, surprise, wonder. Not rote memory.
2. **Universal over Niche** — International audience. No US-specific, no English wordplay.
3. **Narrative over Facts** — Tell a story. Not isolated facts.
4. **Clever over Straightforward** — Creative framing. Never "What is..." or "Who wrote...".

### Boring Detector (REJECT if any apply)

- "What is the capital of...", "Who wrote...", "What year did..."
- Pure memorization (chemical symbols, dates, names)
- Niche references (video games, obscure films, specific sports stats)
- US-specific content (unless explicitly requested)
- Language-dependent wordplay (puns, anagrams that only work in English)
- Predictable answers from question wording

### 4. Generate MORE than requested, keep the best

Generate ~30-50% more candidates than the requested count. Score them all, then select only the top N that score 8.0+. If difficulty is "mixed", aim for roughly: 20% easy, 50% medium, 30% hard.

### 5. Save Output

Save the questions to `data/generated/claude_batch_NNN.json` where NNN is the next available number. Use this exact JSON structure:

```json
{
  "questions": [
    {
      "question": "Question text?",
      "type": "text",
      "correct_answer": "Answer",
      "possible_answers": null,
      "alternative_answers": ["answer", "answer variant"],
      "topic": "Topic",
      "category": "adults",
      "difficulty": "medium",
      "tags": ["tag1", "tag2"],
      "language_dependent": false,
      "source": "generated",
      "source_url": "https://en.wikipedia.org/wiki/...",
      "source_excerpt": "Brief 1-2 sentence excerpt confirming the answer.",
      "review_status": "pending_review",
      "generation_metadata": {
        "model": "claude-opus-4-6",
        "provider": "anthropic",
        "prompt_version": "v2_cot",
        "stage": "claude_code_session",
        "reasoning": { "pattern_used": "...", "why_interesting": "...", "universal_appeal": "...", "boring_check": "..." },
        "self_critique": { "surprise_factor": 9, "universal_appeal": 9, "clever_framing": 9, "educational_value": 9, "clarity": 9, "factual_accuracy": 9, "overall_score": 9.0, "reasoning": "..." },
        "ai_score": 9.0
      }
    }
  ],
  "metadata": {
    "model": "claude-opus-4-6",
    "provider": "anthropic",
    "generated_at": "<ISO timestamp>",
    "total_generated": 13,
    "total_selected": 10,
    "pipeline": "claude_code_session",
    "prompt_version": "v2_cot"
  }
}
```

### 6. Present Results

Show a ranked summary table of the selected questions:

```
  #  Score  Diff    Topic         Question
  1   9.3   hard    Nature        Which creature has survived...
  2   9.0   medium  History       Which classic board game...
```

### 7. Ask About Import

After presenting results, ask the user if they want to import to ChromaDB for review in the web UI. If yes, run:

```bash
.venv/bin/python scripts/generate_questions_claude.py -i data/generated/claude_batch_NNN.json --count <N> --import-to-db
```

Then remind them to start the question generator if not already running:
```bash
# /start-local questions
```
And visit `http://localhost:8003/web/review` to rate them.

### 8. Suggest Verification

After import, suggest running the verification skill:

> "Consider running `/verify-questions data/generated/claude_batch_NNN.json` to fact-check answers and populate source attribution (URLs + excerpts) for the iOS app's source card."

## Important

- **Factual accuracy is critical.** Only include facts you are confident about. If unsure, skip the question — never guess.
- **Avoid duplicating questions** already generated. Check existing files in `data/generated/` before finalizing.
- **alternative_answers** should include lowercase variants and common alternative phrasings.
- **language_dependent** should be `true` only if the question fundamentally relies on English spelling/wordplay.
- **source_url / source_excerpt** — Include when you're confident of a reliable source. These power the iOS app's SourceCard on the result screen. If unsure, leave null and let `/verify-questions` find them.
