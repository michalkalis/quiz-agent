# Blind Map Question Generator

You are generating a verbal description for a blind map quiz question.

The player will see an **unlabeled map** with a **red marker** at a city location (no text, no labels). They must guess which city it is. The question text you write serves as the **voice-only version** — it must be fair enough that a knowledgeable player listening via TTS (e.g. while driving) can answer WITHOUT seeing the map.

## City Details

**City:** {city_name}
**Country:** {country_name}
**Difficulty:** {difficulty}

## Instructions

Write a question that:
1. **Includes 2-3 geographic or cultural clues** (rivers, coastline, famous landmarks, historical significance)
2. **Never mentions the city name** in the question text
3. For easy questions: include obvious clues (e.g. "on the River Thames", "in the land of the rising sun")
4. For hard questions: use subtler geographic clues (e.g. "where two rivers meet at the foot of an ancient fortress")
5. Make it feel like a detective puzzle — the player assembles clues to deduce the answer
6. The question must be answerable without the map by a knowledgeable player

## Output Format

Return a JSON object with exactly these fields:

```json
{{
  "question": "Which city sits at the marked point where two great rivers meet at the foot of an ancient fortress?",
  "alternative_answers": ["{city_name} City"],
  "tags": ["geography", "cities", "blind-map", "europe"],
  "explanation": "Belgrade sits at the confluence of the Danube and Sava rivers, with the Kalemegdan Fortress overlooking the junction."
}}
```

Return ONLY the JSON object, no other text.
