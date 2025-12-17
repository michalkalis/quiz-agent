# ChatGPT Manual Question Generation Guide

This guide provides prompts you can copy-paste into ChatGPT to generate high-quality pub quiz questions manually.

## Why Use ChatGPT Manually?

Since you're already paying for ChatGPT, you can:
- Generate questions without API costs
- Iterate quickly on prompts
- Test different approaches
- Build your review dataset

---

## Prompt 1: Advanced Generation (Recommended)

**Copy this entire prompt to ChatGPT:**

```
You are an expert pub quiz master creating engaging, clever, memorable trivia questions.

## Your Task

Generate 10 medium difficulty pub quiz questions for adults.

## CRITICAL: Quality-First Generation Process

For EACH question, follow this process:

### Step 1: REASONING (Before generating)
Think through:
1. **What pattern am I using?** (See Pattern Library below)
2. **Why is this interesting?** (Surprise factor, "aha!" moment)
3. **Is this universally appealing?** (Works across cultures)
4. **Boring check passed?**

### Step 2: GENERATE the question

### Step 3: SELF-CRITIQUE
Rate 1-10 on:
- Surprise Factor
- Universal Appeal
- Clever Framing
- Educational Value

Overall Score = Average

### Step 4: DECISION
- Score ≥ 8: Keep it
- Score < 8: Explain what's wrong and regenerate

---

## Pattern Library

### Pattern 1: The Surprising Connection
**Template:** "Which [common thing] has [unexpected property/connection]?"

**Examples:**
- "Which spice was so prized the Dutch traded Manhattan for it?" → Nutmeg
- "Which breakfast food was invented as health food for sanitarium patients?" → Corn Flakes

### Pattern 2: The Hidden Property
**Template:** "Which [familiar thing] has [bizarre property]?"

**Examples:**
- "Which animal has cube-shaped feces for territory marking?" → Wombat
- "Which planet has a hexagon-shaped storm at its north pole?" → Saturn

### Pattern 3: The Wordplay Revelation
**Examples:**
- "Which writer's name is an anagram of 'I am a weakish speller'?" → William Shakespeare
- "What is the only number spelled with the same number of letters as its value?" → Four

### Pattern 4: The Scale Surprise
**Examples:**
- "Which country has more lakes than the rest of the world combined?" → Canada
- "How many hearts does an octopus have?" → Three

### Pattern 5: The Historical Quirk
**Examples:**
- "Which soft drink was originally sold as a nerve tonic?" → Coca-Cola
- "Which children's toy was developed as wallpaper cleaner?" → Play-Doh

### Pattern 6: The Biological/Physical Oddity
**Examples:**
- "Which sea creature can regrow its brain after being cut in half?" → Planarian flatworm
- "Which bird can fly backwards?" → Hummingbird

---

## The Boring Detector: AVOID These Red Flags

❌ **Format Red Flags:**
- "What is the capital of..."
- "Who wrote..."
- "What year did..."

❌ **Content Red Flags:**
- Pure memorization (chemical symbols, dates)
- Niche references (video games, obscure films)
- US-specific content
- Predictable answers

**If you hit ANY red flag, regenerate using a different pattern!**

---

## Constitutional Principles

Every question must align with:

### PRINCIPLE 1: Delight over Memorization
Create joy/surprise, not memory tests.

**Good:** "Which animal sleeps standing up by locking its legs?" → Horse
**Bad:** "What is the chemical symbol for mercury?" → Hg

### PRINCIPLE 2: Universal over Niche
Work for international audiences.

**Good:** "Which country has a non-rectangular flag?" → Nepal
**Bad:** "Which quarterback won Super Bowl 2015?" → (US-specific)

### PRINCIPLE 3: Narrative over Facts
Tell a story, create context.

**Good:** "Which Pharaoh's tomb was found almost intact in 1922?" → Tutankhamun
**Bad:** "Who was the youngest Pharaoh?" → Tutankhamun

### PRINCIPLE 4: Clever over Straightforward
Creative framing or unexpected angles.

**Good:** "Which fruit is NOT a berry despite its name?" → Strawberry
**Bad:** "What fruit is red and used in pies?" → Apple

---

## Response Format

Return JSON:

```json
{
  "questions": [
    {
      "reasoning": {
        "pattern_used": "Pattern 2: Hidden Property",
        "why_interesting": "Surprising fact about familiar animal",
        "universal_appeal": "Animals are universally known",
        "boring_check": "No red flags - uses creative framing"
      },
      "question": "Which animal has cube-shaped feces, believed to help mark territory?",
      "type": "text",
      "correct_answer": "Wombat",
      "alternative_answers": ["wombat", "wombats"],
      "topic": "Biology",
      "category": "adults",
      "difficulty": "medium",
      "tags": ["animals", "biology", "quirky-facts"],
      "self_critique": {
        "surprise_factor": 9,
        "universal_appeal": 10,
        "clever_framing": 8,
        "educational_value": 9,
        "overall_score": 9.0,
        "reasoning": "Highly surprising fact, universally accessible, clever framing, very memorable"
      }
    }
  ]
}
```

---

## Final Reminder

1. **REASON** about the pattern
2. **GENERATE** the question
3. **CRITIQUE** honestly
4. **REGENERATE** if score < 8
5. **RETURN** only 8+ scored questions

Your goal: Questions that make people smile, learn something new, and say "That's a great question!"

Now generate 10 questions following this process.
```

---

## Prompt 2: Quick Generation (Simpler)

For faster generation without all the reasoning:

```
Generate 10 pub quiz questions following these rules:

MUST HAVE:
- Surprising facts or clever connections
- Universal appeal (no US-specific or niche content)
- Creative framing (not "What is..." format)
- Educational value

AVOID:
- Pure memorization (chemical symbols, dates)
- Video game or obscure film references
- Boring "Who wrote..." or "What year..." format
- Predictable answers

Use these PATTERNS:
1. Surprising Connection: "Which [common thing] has [unexpected property]?"
2. Hidden Property: "Which [familiar thing] has [bizarre feature]?"
3. Wordplay: Anagrams, linguistic tricks
4. Scale Surprise: Unexpectedly large/small/many
5. Historical Quirk: "Which [modern thing] was originally [surprising use]?"
6. Oddity: "Which [creature] can [amazing ability]?"

EXAMPLES OF EXCELLENT QUESTIONS:
- "Which writer's name is an anagram of 'I am a weakish speller'?" → William Shakespeare
- "Which animal has cube-shaped feces?" → Wombat
- "Which spice did the Dutch trade Manhattan for?" → Nutmeg
- "Which planet has a hexagon storm?" → Saturn

Return as JSON:
{
  "questions": [
    {
      "question": "...",
      "correct_answer": "...",
      "alternative_answers": [],
      "topic": "...",
      "difficulty": "medium",
      "tags": []
    }
  ]
}
```

---

## How to Use These Prompts

### Step 1: Generate
1. Open ChatGPT
2. Copy-paste Prompt 1 (recommended) or Prompt 2
3. Adjust parameters:
   - Change "10" to your desired count
   - Change "medium" to easy/hard
   - Add topic preferences: "Generate 10 medium science questions..."

### Step 2: Review Output
- ChatGPT will return JSON with questions
- Check self-critique scores (look for 8+)
- If quality is low, ask: "Regenerate questions with scores < 8 using different patterns"

### Step 3: Import to System
1. Copy the JSON output
2. Save to a file: `questions_batch_1.json`
3. Use the import API endpoint:
   ```bash
   curl -X POST http://localhost:8000/api/v1/import \
     -H "Content-Type: application/json" \
     -d @questions_batch_1.json
   ```

### Step 4: Review in System
- Questions will have status: `pending_review`
- Use the review UI to rate them
- Approve good ones for use in quizzes

---

## Tips for Best Results

### 1. Be Specific with Topics
Instead of: "Generate 10 questions"
Use: "Generate 10 medium difficulty science questions about astronomy and physics"

### 2. Request Diversity
"Generate 10 questions using 6 different patterns from the Pattern Library"

### 3. Iterate on Low Scores
"The last batch had average score 6.5. Regenerate focusing on surprise factor and clever framing."

### 4. Mix Difficulties
"Generate 3 easy, 4 medium, 3 hard questions about history"

### 5. Avoid Repetition
"Generate 10 questions, ensuring no two use the same pattern"

---

## Example Session

**You:** [Copy Prompt 1, modify to "Generate 5 hard science questions"]

**ChatGPT:** [Returns 5 questions with reasoning and scores]

**You:** "The question about chemical formulas scored 6.2. Regenerate it using Pattern 2 (Hidden Property) instead."

**ChatGPT:** [Returns improved version]

**You:** "Perfect! Now generate 5 more using Patterns 4, 5, and 6 only."

**ChatGPT:** [Returns 5 more questions]

---

## Tracking Your Progress

Keep a log:
```
Batch 1 (2025-12-17): 10 questions, avg score 8.2, imported
Batch 2 (2025-12-17): 5 questions, avg score 9.1, imported
Batch 3 (2025-12-18): 10 questions, avg score 7.8, needs revision
```

This helps you:
- Build your review dataset for fine-tuning
- Track quality improvements
- Identify which patterns work best

---

## Next Steps

Once you have 50-100 rated questions:
1. Export them with your ratings
2. Create preference pairs (good vs bad)
3. Use for DPO fine-tuning (Phase 3)

For now, focus on:
- Generating diverse questions
- Rating them honestly
- Building your approved question library
- Testing different patterns and topics

Happy question generating!
