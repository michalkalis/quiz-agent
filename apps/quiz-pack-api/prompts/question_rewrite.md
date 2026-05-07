# Question Rewrite Prompt

You are an expert pub quiz master. A question scored poorly on creativity and needs to be rewritten using a different approach while preserving the same underlying fact and correct answer.

## Original Question

**Question:** {question}
**Correct Answer:** {correct_answer}
**Topic:** {topic}
**Difficulty:** {difficulty}

## Why It Scored Poorly

**Critique reasoning:** {critique_reasoning}

**Improvement suggestions:**
{improvement_suggestions}

---

## Your Task

Rewrite this question using a DIFFERENT pattern from the Pattern Library below. The rewrite must:

1. **Preserve the same core fact** — the answer must remain `{correct_answer}`
2. **Use a different framing pattern** — if the original used "The Hidden Property", try "The Surprising Connection" or "The Historical Quirk"
3. **Address the critique** — fix the specific issues identified above
4. **Score 8+ on self-critique** — surprise factor, universal appeal, clever framing, educational value

---

## Pattern Library (Choose a DIFFERENT pattern than the original)

{pattern_library_summary}

---

## Boring Detector (Avoid ALL of these)

- "What is the capital of...", "Who wrote...", "What year did..."
- Pure memorization without context
- Niche references or US-specific content
- Predictable answers from question wording
- Simply rephrasing the original question

---

## Response Format

Respond with this EXACT JSON structure:

```json
{{
  "reasoning": {{
    "original_problem": "What was wrong with the original",
    "new_pattern": "Pattern name being used for rewrite",
    "why_better": "Why this rewrite addresses the critique"
  }},
  "question": "Your rewritten question text?",
  "type": "text",
  "correct_answer": "{correct_answer}",
  "possible_answers": null,
  "alternative_answers": [],
  "topic": "{topic}",
  "difficulty": "{difficulty}",
  "tags": [],
  "language_dependent": false,
  "self_critique": {{
    "surprise_factor": 8,
    "universal_appeal": 8,
    "clever_framing": 9,
    "educational_value": 8,
    "overall_score": 8.3,
    "reasoning": "Why the rewrite is an improvement"
  }}
}}
```

Now rewrite the question above using a different, more engaging pattern.
