"""
Quiz Agent Graph - LangGraph state machine for pub-quiz agent.
"""

import json
import re
from typing import Annotated, Literal
from typing_extensions import TypedDict
from langchain_openai import ChatOpenAI
from langgraph.graph import StateGraph, END
from langgraph.graph.message import add_messages
from langchain_core.messages import HumanMessage, SystemMessage
import os


# =============================================================================
# STATE SCHEMA
# =============================================================================

class QuizState(TypedDict):
    """Quiz agent state."""
    messages: Annotated[list, add_messages]
    phase: str  # idle, asking, awaiting_answer, evaluating, finding_source, providing_feedback, finished
    question_number: int
    max_questions: int
    current_question: str | None
    current_answer: str | None
    current_difficulty: str  # easy, medium, hard
    current_topic: str | None
    last_user_answer: str | None
    last_result: str | None  # correct, partially_correct, partially_incorrect, incorrect, skipped
    score: float
    last_source_url: str | None
    last_source_snippet: str | None
    pending_output: str | None
    asked_questions: list[str]  # Track asked questions to avoid repetition
    excluded_topics: list[str]  # Topics to avoid (e.g., ["chemistry", "sports"])
    preferred_topics: list[str]  # Topics to prefer (e.g., ["history", "science"])
    bad_examples: list[str]  # Questions user didn't like (session only)
    skipped_question_numbers: list[int]  # Track which question numbers were skipped
    auto_advance: bool  # Flag to trigger auto-advance after bad_question


# =============================================================================
# QUIZ QUESTION GENERATION PROMPT
# =============================================================================

def load_quiz_prompt_template() -> str:
    """Load the quiz prompt template from file."""
    prompt_file = os.path.join(os.path.dirname(__file__), "pub_quiz_generation_prompt.md")
    with open(prompt_file, "r", encoding="utf-8") as f:
        return f.read()


# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

def normalize_text(text: str) -> str:
    """Normalize text for comparison."""
    text = text.lower().strip()
    text = re.sub(r'[.,!?;:\'"()-]', '', text)
    text = re.sub(r'\s+', ' ', text)
    return text


def get_tavily_mcp_url():
    """Get Tavily MCP URL with API key."""
    api_key = os.getenv("TAVILY_API_KEY")
    if not api_key:
        raise ValueError("TAVILY_API_KEY not found")
    return f"https://mcp.tavily.com/mcp/?tavilyApiKey={api_key}"


def create_intent_classifier_prompt(user_input: str, current_question: str = "") -> str:
    """Create prompt for multi-intent classification of user input."""
    return f"""Classify this quiz user input into one or more intent types. A single input can contain MULTIPLE intents.

Current question: {current_question if current_question else "No question asked yet"}
User input: {user_input}

INTENT TYPES:
1. "answer" - User is answering the current quiz question
2. "skip" - User wants to skip this question (words like: skip, pass, next, idk, "i don't know")
3. "bad_question" - User dislikes this question (phrases like: "I don't like this question", "bad question", "this is a terrible question")
4. "preference_change" - User wants to change topic preferences or difficulty
5. "start" - User wants to begin the quiz
6. "explanation_request" - User is asking for clarification about something in the question
7. "unclear" - Irrelevant text that should be ignored

EXTRACTION RULES:
- For "answer": Extract just the answer text
- For "skip": No additional data needed
- For "bad_question": No additional data needed, but generate a confirmation message
- For "preference_change": Extract avoid_topics (list), prefer_topics (list), and/or difficulty ("harder" or "easier")
- For "explanation_request": Extract what user wants explained
- For "unclear": Mark as ignored

MULTI-INTENT EXAMPLES:
- "London. No more geography" → [answer, preference_change]
- "Paris. I don't like this question" → [answer, bad_question]
- "Berlin. What's for dinner?" → [answer] (ignore irrelevant)
- "42. Make it harder" → [answer, preference_change]
- "skip" → [skip]
- "What is a quasar?" → [explanation_request]

CONFIRMATION MESSAGES:
Generate user-friendly confirmation messages for preference_change and bad_question intents.
Examples:
- "Got it! Avoiding geography questions from now on."
- "Making questions harder - challenge accepted!"
- "Noted - I'll avoid questions like this one."
- "I'll skip this question. Say 'next' when ready!"

Respond in this exact JSON format:
{{
    "intents": [
        {{
            "intent_type": "answer|skip|bad_question|preference_change|start|explanation_request|unclear",
            "extracted_data": {{
                "answer": "text" (for answer),
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


# =============================================================================
# NODE FUNCTIONS
# =============================================================================

def create_process_input_node(llm: ChatOpenAI):
    """Create input processing node with multi-intent classification."""

    async def process_input(state: QuizState) -> dict:
        phase = state.get("phase", "idle")

        # Get last user message
        messages = state.get("messages", [])
        user_input = ""
        for msg in reversed(messages):
            if isinstance(msg, HumanMessage):
                user_input = msg.content
                break
            elif isinstance(msg, tuple) and msg[0] == "user":
                user_input = msg[1]
                break

        user_input_lower = user_input.lower().strip()

        # Fast path: Handle quit with simple string matching
        if user_input_lower in ["quit", "exit", "stop", "end"]:
            current_q = state['question_number']
            final_score = current_q - 1 if current_q > 0 else 0
            skipped_count = len(state.get("skipped_question_numbers", []))
            total_answered = final_score - skipped_count

            if total_answered <= 0:
                pending = f"\nQuiz ended. No questions answered."
            else:
                pending = f"\nQuiz ended. Final score: {state['score']}/{total_answered}"

            return {
                "phase": "finished",
                "pending_output": pending
            }

        # Fast path: Handle list/bad/excluded commands
        if user_input_lower in ["bad", "excluded", "list"]:
            bad_examples = state.get("bad_examples", [])
            if not bad_examples:
                return {
                    "pending_output": "No questions have been marked as bad yet."
                }
            else:
                # Format as numbered list
                output_lines = ["Questions marked as bad:"]
                for idx, question in enumerate(bad_examples, 1):
                    output_lines.append(f"{idx}. {question}")
                return {
                    "pending_output": "\n".join(output_lines)
                }

        # Fast path: Handle start in idle phase with simple string matching
        if phase == "idle" and user_input_lower in ["start", "begin"]:
            return {"phase": "asking", "question_number": 1, "score": 0.0}

        # For everything else, use multi-intent LLM classifier
        current_question = state.get("current_question", "")
        classifier_prompt = create_intent_classifier_prompt(user_input, current_question)

        response = await llm.ainvoke([
            SystemMessage(content="You classify quiz user inputs into intents. Always respond with valid JSON."),
            HumanMessage(content=classifier_prompt)
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
                intents = [{"intent_type": "answer", "extracted_data": {"answer": user_input}, "confirmation_message": None}]
        except (json.JSONDecodeError, KeyError):
            # Fallback: treat as simple answer
            intents = [{"intent_type": "answer", "extracted_data": {"answer": user_input}, "confirmation_message": None}]

        # Process all intents
        result = {}
        confirmation_messages = []
        has_answer = False
        should_skip = False
        should_auto_advance = False

        for intent in intents:
            intent_type = intent.get("intent_type", "")
            extracted = intent.get("extracted_data", {})
            confirmation = intent.get("confirmation_message")

            # Handle each intent type
            if intent_type == "answer":
                has_answer = True
                result["last_user_answer"] = extracted.get("answer", user_input)
                result["phase"] = "evaluating"

            elif intent_type == "skip":
                should_skip = True
                result["phase"] = "evaluating"
                result["last_user_answer"] = ""
                result["last_result"] = "skipped"
                # Track skipped question number
                skipped_nums = list(state.get("skipped_question_numbers", []))
                skipped_nums.append(state["question_number"])
                result["skipped_question_numbers"] = skipped_nums
                if confirmation:
                    confirmation_messages.append(confirmation)
                else:
                    confirmation_messages.append("Skipping this question.")

            elif intent_type == "bad_question":
                # Add current question to bad examples
                bad_examples = list(state.get("bad_examples", []))
                if current_question and current_question not in bad_examples:
                    bad_examples.append(current_question)
                    result["bad_examples"] = bad_examples

                # Store confirmation message
                if confirmation:
                    confirmation_messages.append(confirmation)
                else:
                    confirmation_messages.append("Got it, I'll avoid similar questions.")

                # Mark for auto-advance if awaiting answer
                if phase == "awaiting_answer":
                    should_auto_advance = True

            elif intent_type == "preference_change":
                # Handle topic preferences
                excluded = list(state.get("excluded_topics", []))
                preferred = list(state.get("preferred_topics", []))

                avoid_topics = extracted.get("avoid_topics", [])
                prefer_topics = extracted.get("prefer_topics", [])

                for topic in avoid_topics:
                    if topic and topic not in excluded:
                        excluded.append(topic)
                if avoid_topics:
                    result["excluded_topics"] = excluded

                for topic in prefer_topics:
                    if topic and topic not in preferred:
                        preferred.append(topic)
                if prefer_topics:
                    result["preferred_topics"] = preferred

                # Handle difficulty change
                if extracted.get("difficulty"):
                    difficulties = ["easy", "medium", "hard"]
                    current_idx = difficulties.index(state["current_difficulty"])
                    if extracted["difficulty"] == "easier":
                        new_difficulty = difficulties[max(0, current_idx - 1)]
                    else:
                        new_difficulty = difficulties[min(2, current_idx + 1)]
                    result["current_difficulty"] = new_difficulty

                # Add confirmation message
                if confirmation:
                    confirmation_messages.append(confirmation)

            elif intent_type == "start":
                result["phase"] = "asking"
                result["question_number"] = 1
                result["score"] = 0.0

            elif intent_type == "explanation_request":
                # Generate explanation without revealing answer
                explain_what = extracted.get("explanation_request", "")
                explain_prompt = f"""The user is playing a quiz and needs clarification.

Question: {current_question}
User asks about: {explain_what}

Provide a brief, helpful explanation WITHOUT giving away the answer to the quiz question.
Keep it concise (1-2 sentences)."""

                explain_response = await llm.ainvoke([
                    SystemMessage(content="You help quiz players understand questions without revealing answers."),
                    HumanMessage(content=explain_prompt)
                ])
                confirmation_messages.append(explain_response.content)

            # intent_type "unclear" is ignored

        # Handle idle phase with no clear intent
        if phase == "idle" and not result:
            return {"pending_output": "Type 'start' to begin."}

        # If only confirmations without answer/skip in awaiting_answer phase, stay in that phase
        if phase == "awaiting_answer" and confirmation_messages and not has_answer and not should_skip:
            result["pending_output"] = "\n".join(confirmation_messages)
            # Don't change phase, stay in awaiting_answer
            result.pop("phase", None)
        elif confirmation_messages:
            # Store confirmations to show
            result["pending_output"] = "\n".join(confirmation_messages)

        # Handle auto-advance for bad_question
        if should_auto_advance:
            # If user also provided an answer, evaluate it first
            if has_answer:
                # Phase already set to "evaluating" by answer handler
                # Set flag to trigger auto-advance after feedback
                result["auto_advance"] = True
            else:
                # No answer provided, skip and go directly to next question
                result["phase"] = "asking"
                result["last_result"] = "skipped"
                # Track as skipped
                skipped_nums = list(state.get("skipped_question_numbers", []))
                skipped_nums.append(state["question_number"])
                result["skipped_question_numbers"] = skipped_nums

        return result if result else {}

    return process_input


def create_generate_question_node(llm: ChatOpenAI):
    """Create question generation node."""

    async def generate_question(state: QuizState) -> dict:
        difficulty = state.get("current_difficulty", "medium")
        question_num = state.get("question_number", 1)
        asked = state.get("asked_questions", [])
        previous_feedback = state.get("pending_output", "")
        excluded = state.get("excluded_topics", [])
        preferred = state.get("preferred_topics", [])
        bad_examples = state.get("bad_examples", [])

        # Load prompt template from file
        prompt_template = load_quiz_prompt_template()

        # Build avoid_section with previously asked questions
        avoid_section = ""
        if asked:
            avoid_section = f"\n\nDo NOT repeat or rephrase any of these previously asked questions:\n" + "\n".join(f"- {q}" for q in asked)

        # Build topic_section with topic preferences
        topic_section = ""
        if excluded:
            topic_section += f"\n\nAVOID these topics completely: {', '.join(excluded)}"
        if preferred:
            topic_section += f"\n\nPREFER questions from these topics: {', '.join(preferred)}"

        # Build bad_examples_section with user feedback (combines with static BAD examples in template)
        bad_examples_section = ""
        if bad_examples:
            bad_examples_section = f"""

## AVOID These Questions (User Feedback from This Session)
The user did NOT like these questions from this session:
{chr(10).join(f"- {q}" for q in bad_examples)}

Generate questions DIFFERENT from both the static BAD examples above AND the user feedback questions listed here."""

        # Format the template with all dynamic values
        prompt = prompt_template.format(
            difficulty=difficulty,
            topic_section=topic_section,
            avoid_section=avoid_section,
            bad_examples_section=bad_examples_section
        )

        response = await llm.ainvoke([
            HumanMessage(content=prompt)
        ])

        # Parse response
        try:
            content = response.content
            start = content.find('{')
            end = content.rfind('}') + 1
            if start != -1 and end > start:
                data = json.loads(content[start:end])
                question = data.get("question", "")
                answer = data.get("answer", "")
                topic = data.get("topic", "General")
            else:
                question = "What year did World War II end?"
                answer = "1945"
                topic = "History"
        except (json.JSONDecodeError, KeyError):
            question = "What year did World War II end?"
            answer = "1945"
            topic = "History"

        # Combine previous feedback with new question
        output = f"Q{question_num}: {question}"
        if previous_feedback:
            output = f"{previous_feedback}\n\n{output}"

        return {
            "current_question": question,
            "current_answer": answer,
            "current_topic": topic,
            "phase": "awaiting_answer",
            "pending_output": output,
            "asked_questions": asked + [question]
        }

    return generate_question


def create_evaluate_answer_node(llm: ChatOpenAI):
    """Create answer evaluation node."""

    async def evaluate_answer(state: QuizState) -> dict:
        user_answer = state.get("last_user_answer", "")
        correct_answer = state.get("current_answer", "")
        question = state.get("current_question", "")

        if not user_answer or state.get("last_result") == "skipped":
            # Track skipped question
            skipped_nums = list(state.get("skipped_question_numbers", []))
            skipped_nums.append(state["question_number"])
            return {
                "last_result": "skipped",
                "phase": "finding_source",
                "skipped_question_numbers": skipped_nums
            }

        # Quick exact match
        if normalize_text(user_answer) == normalize_text(correct_answer):
            return {"last_result": "correct", "score": state["score"] + 1.0, "phase": "finding_source"}

        # LLM evaluation
        eval_prompt = f"""You are a fair quiz answer evaluator. Compare the user's answer to the correct answer.

Question: {question}
Correct Answer: {correct_answer}
User's Answer: {user_answer}

Rules:
- "correct": The answer captures the key concept correctly. Accept:
  - Shorter forms that contain the essential element (e.g., "sequoia" for "giant sequoia", "carbon" for "carbon dioxide")
  - Common abbreviations (NYC for New York City, WW2 for World War II)
  - Minor spelling errors that don't change the meaning
  - More specific correct answers (e.g., "carbon dioxide" when answer is "carbon")
- "partially_correct": Has the right general idea but missing important qualifiers or has minor factual errors
- "partially_incorrect": Mentions something related but is mostly wrong
- "incorrect": Completely wrong, unrelated, or nonsensical answer

The key principle: if the user clearly knows the answer, mark it correct.
If they're in the right ballpark but not quite there, mark it partially_correct.

Respond with EXACTLY one of these words: correct, partially_correct, partially_incorrect, incorrect"""

        response = await llm.ainvoke([
            SystemMessage(content="You are a fair quiz evaluator. Accept answers that demonstrate the user knows the correct information."),
            HumanMessage(content=eval_prompt)
        ])

        result_text = response.content.lower().strip()

        # Parse result more strictly - check for exact matches first
        if result_text == "incorrect":
            return {"last_result": "incorrect", "score": state["score"], "phase": "finding_source"}
        elif result_text == "partially_incorrect":
            return {"last_result": "partially_incorrect", "score": state["score"] + 0.25, "phase": "finding_source"}
        elif result_text == "partially_correct":
            return {"last_result": "partially_correct", "score": state["score"] + 0.5, "phase": "finding_source"}
        elif result_text == "correct":
            return {"last_result": "correct", "score": state["score"] + 1.0, "phase": "finding_source"}
        # Fallback parsing
        elif "incorrect" in result_text and "partially" not in result_text:
            return {"last_result": "incorrect", "score": state["score"], "phase": "finding_source"}
        elif "partially_incorrect" in result_text:
            return {"last_result": "partially_incorrect", "score": state["score"] + 0.25, "phase": "finding_source"}
        elif "partially_correct" in result_text:
            return {"last_result": "partially_correct", "score": state["score"] + 0.5, "phase": "finding_source"}
        elif "correct" in result_text:
            return {"last_result": "correct", "score": state["score"] + 1.0, "phase": "finding_source"}
        else:
            # Default to incorrect if unclear
            return {"last_result": "incorrect", "score": state["score"], "phase": "finding_source"}

    return evaluate_answer


def create_find_source_node(llm: ChatOpenAI, tools: list):
    """Create source finding node."""

    # Trustworthy domains to prioritize
    TRUSTED_DOMAINS = [
        "wikipedia.org",
        "britannica.com",
        "wolframalpha.com",
        "nasa.gov",
        "smithsonianmag.com",
        "nationalgeographic.com",
        "bbc.com",
        "reuters.com",
        "nature.com",
        "sciencedirect.com",
        "history.com",
        "guinnessworldrecords.com",
    ]

    async def find_source(state: QuizState) -> dict:
        answer = state.get("current_answer", "")
        topic = state.get("current_topic", "")

        # Search query focused on Wikipedia
        search_query = f"{answer} {topic} site:wikipedia.org"

        # Find search tool
        search_tool = None
        for tool in tools:
            if "search" in tool.name.lower():
                search_tool = tool
                break

        if not search_tool:
            return {"last_source_url": None, "last_source_snippet": None, "phase": "providing_feedback"}

        try:
            result = await search_tool.ainvoke({"query": search_query})

            if isinstance(result, str):
                try:
                    result_data = json.loads(result)
                except json.JSONDecodeError:
                    result_data = {}
            else:
                result_data = result

            url = None
            snippet = None

            if isinstance(result_data, dict):
                results = result_data.get("results", [])

                # First, try to find a trusted source
                for res in results:
                    res_url = res.get("url", "")
                    if any(domain in res_url for domain in TRUSTED_DOMAINS):
                        url = res_url
                        snippet = res.get("content", "")[:150]
                        break

                # Fallback to first result if no trusted source found
                if not url and results:
                    url = results[0].get("url", "")
                    snippet = results[0].get("content", "")[:150]

            return {"last_source_url": url, "last_source_snippet": snippet, "phase": "providing_feedback"}

        except Exception:
            return {"last_source_url": None, "last_source_snippet": None, "phase": "providing_feedback"}

    return find_source


def create_provide_feedback_node():
    """Create feedback node."""

    async def provide_feedback(state: QuizState) -> dict:
        result = state.get("last_result", "incorrect")
        correct_answer = state.get("current_answer", "")
        source_url = state.get("last_source_url")
        previous_output = state.get("pending_output", "")
        auto_advance = state.get("auto_advance", False)

        # Build feedback
        if result == "correct":
            feedback = "Correct."
        elif result == "partially_correct":
            feedback = f"Partially correct. Answer: {correct_answer}"
        elif result == "partially_incorrect":
            feedback = f"Partially incorrect. Answer: {correct_answer}"
        elif result == "skipped":
            feedback = f"Skipped. Answer: {correct_answer}"
        else:
            feedback = f"Incorrect. Answer: {correct_answer}"

        if source_url:
            feedback += f"\nSource: {source_url}"
        else:
            feedback += "\nNo source found."

        # Calculate denominator excluding skipped questions
        skipped_count = len(state.get("skipped_question_numbers", []))
        total_answered = state["question_number"] - skipped_count

        if total_answered == 0:
            feedback += f"\n[Score: No questions answered yet]"
        else:
            feedback += f"\n[Score: {state['score']}/{total_answered}]"

        # Prepend any confirmation messages from input processing (e.g., "Noted - I'll avoid...")
        if previous_output and not previous_output.startswith("Q"):
            feedback = f"{previous_output}\n\n{feedback}"

        # Auto-advance to next question or finish
        if state["question_number"] >= state["max_questions"]:
            # Quiz complete
            if total_answered == 0:
                feedback += f"\n\nQuiz complete! No questions answered."
            else:
                feedback += f"\n\nQuiz complete! Final score: {state['score']}/{total_answered}"
            return {
                "pending_output": feedback,
                "phase": "finished",
                "auto_advance": False
            }
        else:
            return {
                "pending_output": feedback,
                "phase": "asking",
                "question_number": state["question_number"] + 1,
                "auto_advance": False
            }

    return provide_feedback


# =============================================================================
# GRAPH CONSTRUCTION
# =============================================================================

async def create_quiz_graph(mcp_tools: list = None):
    """Create and compile the quiz StateGraph."""
    llm = ChatOpenAI(model="gpt-4o-mini", temperature=0.7)

    # Create nodes
    process_input = create_process_input_node(llm)
    generate_question = create_generate_question_node(llm)
    evaluate_answer = create_evaluate_answer_node(llm)
    provide_feedback = create_provide_feedback_node()

    # Build graph
    graph_builder = StateGraph(QuizState)

    graph_builder.add_node("process_input", process_input)
    graph_builder.add_node("generate_question", generate_question)
    graph_builder.add_node("evaluate_answer", evaluate_answer)
    graph_builder.add_node("provide_feedback", provide_feedback)

    if mcp_tools:
        find_source = create_find_source_node(llm, mcp_tools)
        graph_builder.add_node("find_source", find_source)
    else:
        async def skip_source(state: QuizState) -> dict:
            return {"last_source_url": None, "last_source_snippet": None, "phase": "providing_feedback"}
        graph_builder.add_node("find_source", skip_source)

    graph_builder.set_entry_point("process_input")

    # Routing
    def route_after_input(state: QuizState) -> str:
        phase = state.get("phase", "idle")
        if phase == "asking":
            return "generate_question"
        elif phase == "evaluating":
            return "evaluate_answer"
        return END

    def route_after_feedback(state: QuizState) -> str:
        phase = state.get("phase", "idle")
        if phase == "asking":
            return "generate_question"
        elif phase == "finished":
            return END
        return END

    graph_builder.add_conditional_edges("process_input", route_after_input,
        {"generate_question": "generate_question", "evaluate_answer": "evaluate_answer", END: END})
    graph_builder.add_edge("generate_question", END)
    graph_builder.add_edge("evaluate_answer", "find_source")
    graph_builder.add_edge("find_source", "provide_feedback")
    graph_builder.add_conditional_edges("provide_feedback", route_after_feedback,
        {"generate_question": "generate_question", END: END})

    return graph_builder.compile()


def get_initial_state() -> QuizState:
    """Get initial state for new quiz session."""
    return {
        "messages": [],
        "phase": "idle",
        "question_number": 0,
        "max_questions": 10,
        "current_question": None,
        "current_answer": None,
        "current_difficulty": "medium",
        "current_topic": None,
        "last_user_answer": None,
        "last_result": None,
        "score": 0.0,
        "last_source_url": None,
        "last_source_snippet": None,
        "pending_output": "Pub Quiz! Type 'start' to begin.",
        "asked_questions": [],
        "excluded_topics": [],
        "preferred_topics": [],
        "bad_examples": [],
        "skipped_question_numbers": [],
        "auto_advance": False
    }
