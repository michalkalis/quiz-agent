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

## Language Portability (HARD RULE)

Sessions are served in Slovak, Czech, German and other languages, so every question must stay TRUE when its text is translated literally. Before emitting a question, translate it word-for-word in your head: if the answer turns false, nonsensical, or into a different word, the question is not portable.

Set `language_dependent: true` whenever the fact holds only as an English lexical convention:
- spelling, letter counts, acronyms, puns, anagrams, rhymes
- **collective nouns** — "a murder of crows" exists only in English; translated literally, "murder" becomes the word for homicide and the question asserts a fabricated fact
- idioms, proverbs, set phrases
- **naming quirks** — anything that turns on what something is *called* in English

Prefer rewriting the question around a fact that survives translation. `language_dependent: true` is the honest fallback, not a free pass: those questions are dropped from every non-English session.

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
