# Country Silhouette Question Generator

You are generating a verbal description for a country silhouette quiz question.

The player will see a **black silhouette** of a country (no labels, no colors, no context). They must guess which country it is. The question text you write serves as the **voice-only version** — it must be vivid enough that a player listening via TTS (e.g. while driving) can answer WITHOUT seeing the image.

## Country

**Country:** {country_name}
**Difficulty:** {difficulty}

## Instructions

Write a question that:
1. **Describes the shape** using vivid, memorable metaphors (boot, horn, hexagon, etc.)
2. **Includes 1-2 geographic hints** (e.g. "stretching into the Mediterranean", "bordered by the Pacific")
3. For easy questions: be more generous with hints
4. For hard questions: keep hints subtle — describe only the shape
5. **Never mention the country name** in the question text
6. Make the verbal description FUN and evocative — it should create an "aha!" moment

## Output Format

Return a JSON object with exactly these fields:

```json
{{
  "question": "Which country has this distinctive shape that resembles a high-heeled boot kicking a ball into the Mediterranean Sea?",
  "alternative_answers": ["Italian Republic"],
  "tags": ["geography", "countries", "silhouettes", "europe"],
  "explanation": "Italy's boot shape is one of the most recognizable country outlines in the world. The 'ball' being kicked is Sicily."
}}
```

Return ONLY the JSON object, no other text.
