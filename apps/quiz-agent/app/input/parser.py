"""AI-powered input parser for natural language quiz interactions.

Ported from graph.py:75-356 with enhancements for rating and multiplayer.
"""

import json
from typing import Dict, List, Optional, Any
from difflib import SequenceMatcher
from langchain_openai import ChatOpenAI
from langchain_core.messages import HumanMessage, SystemMessage


class ParsedIntent(Dict[str, Any]):
    """Parsed intent from user input."""
    pass


class InputParser:
    """Parses natural language input into structured intents.

    This is the core "AI agent" functionality that enables:
    - Natural language understanding
    - Multi-intent extraction
    - Client-agnostic interaction (works for voice, text, remote control)

    Examples:
        "Paris, but I don't like this question" →
            [answer: "Paris", rating: 1]

        "London, no more geography, make it harder" →
            [answer: "London", excluded_topics: ["geography"], difficulty: "harder"]
    """

    def __init__(self, model: str = "gpt-4o-mini", temperature: float = 0.3):
        """Initialize input parser.

        Args:
            model: OpenAI model for intent classification
            temperature: Lower temperature for more deterministic parsing
        """
        self.llm = ChatOpenAI(model=model, temperature=temperature)

    async def parse(
        self,
        user_input: str,
        current_question: str = "",
        phase: str = "idle"
    ) -> List[ParsedIntent]:
        """Parse user input into structured intents.

        Args:
            user_input: Raw user input (text or transcribed speech)
            current_question: Current question text for context
            phase: Current quiz phase for context

        Returns:
            List of parsed intents with extracted data

        Example:
            >>> parser = InputParser()
            >>> intents = await parser.parse(
            ...     "Paris, but this is too easy",
            ...     "What is the capital of France?"
            ... )
            >>> intents[0]["intent_type"]
            'answer'
            >>> intents[0]["extracted_data"]["answer"]
            'Paris'
            >>> intents[1]["intent_type"]
            'rating'
            >>> intents[1]["extracted_data"]["rating"]
            1
        """
        # Fast path for common commands
        user_input_lower = user_input.lower().strip()

        # Fast path for empty input - prevent LLM hallucination
        if not user_input or len(user_input.strip()) < 2:
            return [{
                "intent_type": "skip",
                "extracted_data": {},
                "confirmation_message": "No input received"
            }]

        if phase == "idle" and user_input_lower in ["start", "begin", "play", "go"]:
            return [{"intent_type": "start", "extracted_data": {}, "confirmation_message": None}]

        if user_input_lower in ["quit", "exit", "stop", "end"]:
            return [{"intent_type": "quit", "extracted_data": {}, "confirmation_message": None}]

        if user_input_lower in ["skip", "pass", "next"]:
            return [{"intent_type": "skip", "extracted_data": {}, "confirmation_message": "Skipping question"}]

        # Use LLM for complex input
        prompt = self._create_classifier_prompt(user_input, current_question)

        response = await self.llm.ainvoke([
            SystemMessage(content="You classify quiz user inputs into intents. Always respond with valid JSON."),
            HumanMessage(content=prompt)
        ])

        # Parse JSON response
        try:
            content = response.content
            start = content.find('{')
            end = content.rfind('}') + 1

            if start != -1 and end > start:
                classification = json.loads(content[start:end])
                intents = classification.get("intents", [])
            else:
                # Fallback: treat as simple answer
                intents = [{
                    "intent_type": "answer",
                    "extracted_data": {"answer": user_input},
                    "confirmation_message": None
                }]

        except (json.JSONDecodeError, KeyError) as e:
            print(f"JSON parse error: {e}")
            # Fallback: treat as simple answer
            intents = [{
                "intent_type": "answer",
                "extracted_data": {"answer": user_input},
                "confirmation_message": None
            }]

        # Validate answer intents to prevent question text contamination
        for intent in intents:
            if intent.get("intent_type") == "answer":
                answer = intent.get("extracted_data", {}).get("answer", "")

                # Check if answer suspiciously long (likely captured question)
                if len(answer) > 100:
                    print(f"⚠️ Suspiciously long answer detected ({len(answer)} chars): {answer[:50]}...")
                    print("   Converting to skip to prevent question text contamination")
                    intent["intent_type"] = "skip"
                    intent["extracted_data"] = {}
                    intent["confirmation_message"] = "Answer too long, treating as skip"
                    continue

                # Check if answer is suspiciously similar to question
                if current_question and len(current_question) > 10:
                    similarity = SequenceMatcher(None, answer.lower(), current_question.lower()).ratio()
                    if similarity > 0.7:  # 70% similar to question
                        print(f"⚠️ Answer too similar to question (similarity: {similarity:.2f})")
                        print(f"   Question: {current_question[:50]}...")
                        print(f"   Answer: {answer[:50]}...")
                        print("   Converting to skip to prevent contamination")
                        intent["intent_type"] = "skip"
                        intent["extracted_data"] = {}
                        intent["confirmation_message"] = "Invalid answer detected, treating as skip"

        return intents

    def _create_classifier_prompt(
        self,
        user_input: str,
        current_question: str = ""
    ) -> str:
        """Create prompt for multi-intent classification.

        Enhanced from graph.py:75-131 with rating support.
        """
        return f"""Classify this quiz user input into one or more intent types. A single input can contain MULTIPLE intents.

Current question: {current_question if current_question else "No question asked yet"}
User input: {user_input}

INTENT TYPES:
1. "answer" - User is answering the current quiz question
2. "skip" - User wants to skip this question (words like: skip, pass, next, idk, "i don't know")
3. "rating" - User is rating the question (1-5 scale or sentiment)
4. "preference_change" - User wants to change topic preferences or difficulty
5. "start" - User wants to begin the quiz
6. "explanation_request" - User is asking for clarification about something in the question
7. "quit" - User wants to end the quiz
8. "unclear" - Irrelevant text that should be ignored

EXTRACTION RULES:
- For "answer": Extract ONLY the user's spoken answer, not the question text
  ⚠️ CRITICAL: Maximum answer length is 100 characters (longer = likely contamination)
  ⚠️ If user repeats question before answering (e.g., "What is Paris? Paris"), extract only "Paris"
  ⚠️ If transcription contains only the question with no actual answer, classify as "skip"
  ⚠️ Do NOT include question text, even if it appears in the transcription
- For "skip": No additional data needed
- For "rating": Extract rating (1-5) and optional feedback
  - Negative sentiment ("bad", "terrible", "too easy", "don't like") → rating: 1
  - Positive sentiment ("great", "good", "love it") → rating: 5
  - Explicit number: "rate this 3" → rating: 3
- For "preference_change": Extract avoid_topics (list), prefer_topics (list), and/or difficulty ("harder" or "easier")
- For "explanation_request": Extract what user wants explained
- For "unclear": Mark as ignored

MULTI-INTENT EXAMPLES:
- "London. No more geography" → [answer, preference_change]
- "Paris. I don't like this question" → [answer, rating (1)]
- "Paris. This is too easy" → [answer, rating (1)]
- "Berlin. Great question!" → [answer, rating (5)]
- "42. Make it harder" → [answer, preference_change]
- "skip" → [skip]
- "What is a quasar?" → [explanation_request]

CONFIRMATION MESSAGES:
Generate user-friendly confirmation messages for intents.
Examples:
- "Got it! Avoiding geography questions from now on."
- "Making questions harder - challenge accepted!"
- "Thanks for the feedback!"
- "I'll skip this question."

Respond in this exact JSON format:
{{
    "intents": [
        {{
            "intent_type": "answer|skip|rating|preference_change|start|explanation_request|quit|unclear",
            "extracted_data": {{
                "answer": "text" (for answer),
                "rating": 1-5 (for rating),
                "feedback": "text" (for rating, optional),
                "avoid_topics": ["topic1"] (for preference_change),
                "prefer_topics": ["topic1"] (for preference_change),
                "difficulty": "harder|easier" (for preference_change),
                "explanation_request": "what to explain" (for explanation_request)
            }},
            "confirmation_message": "message to user" or null
        }}
    ],
    "ignored_parts": "irrelevant text" or null
}}"""
