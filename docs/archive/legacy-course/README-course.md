# Quiz Agent

A minimal pub-quiz agent built with LangGraph that can run in terminal and be reused as a backend engine for an iOS quiz app.

## Assignment Context

This project fulfills the AI Developer Course assignment requirements:

**Framework**: LangGraph (StateGraph pattern)
**Tools**: Tavily MCP Server (Model Context Protocol)
**LLM**: OpenAI GPT-4o-mini

**Why MCP?** Following the assignment's recommendation to use MCP instead of framework-specific tools, this implementation connects to Tavily's hosted MCP server (`langchain-mcp-adapters`) for web search functionality. This provides a standardized, protocol-based approach to tool integration.

**Assignment Criteria Met**:
- ✅ Agent framework (LangGraph) with tools integration
- ✅ MCP protocol usage (Tavily MCP server)
- ✅ LLM-based query responses (OpenAI)
- ✅ External tool integration (web search for answer verification)
- ✅ Complete source code with documentation

## Overview

This agent acts as a concise pub-quiz "quizmaster" that:
- Generates trivia questions using LLM
- Evaluates user answers with nuanced scoring
- Provides source links via Tavily MCP
- Tracks score and difficulty

## Architecture

### Existing Codebase Analysis

The quiz agent is built following patterns from the course's `WebOperator` example:

**StateGraph Pattern** (from `11-web-operator/4_Web_operator/agent2_correct/graph.py`):
- State defined as `TypedDict` with `Annotated` types
- `add_messages` reducer for message history
- Conditional edges for routing based on state

**Tool Integration** (from `8_langgraph/5_agent/0_react_manual/main.py`):
- `MultiServerMCPClient` for Tavily MCP connection
- Custom tool node pattern for handling tool calls
- Async invocation with `ainvoke()`

**Operate Pattern** (from `11-web-operator/4_Web_operator/agent2_correct/web_operator.py`):
- Class-based operator with `initialize()` and `run()` methods
- Persistent state across invocations
- Interactive loop with stdin/stdout

### Quiz Agent Architecture

```
┌─────────────┐
│   START     │
└──────┬──────┘
       │
       ▼
┌──────────────┐     ┌────────────────┐
│ process_input│────▶│generate_question│
└──────┬───────┘     └───────┬────────┘
       │                     │
       ▼                     ▼
┌──────────────┐           END (wait for answer)
│evaluate_answer│
└──────┬───────┘
       │
       ▼
┌──────────────┐
│ find_source  │
└──────┬───────┘
       │
       ▼
┌────────────────┐
│provide_feedback│
└───────┬────────┘
        │
        ▼
       END (wait for next input)
```

### State Schema

```python
class QuizState(TypedDict):
    messages: Annotated[list, add_messages]  # LangGraph message reducer
    phase: str              # "idle" | "asking" | "awaiting_answer" | "evaluating" | "finding_source" | "providing_feedback" | "finished"
    question_number: int    # Current question (1-indexed)
    max_questions: int      # Total questions (default 10)
    current_question: str   # Question text
    current_answer: str     # Canonical answer
    current_difficulty: str # "easy" | "medium" | "hard"
    current_topic: str      # Category (History, Science, etc.)
    last_user_answer: str   # User's answer
    last_result: str        # "correct" | "partially_correct" | "partially_incorrect" | "incorrect" | "skipped"
    score: float            # Running score
    last_source_url: str    # Source URL from Tavily
    last_source_snippet: str # Source snippet
    pending_output: str     # Text to display to user
```

### Graph Nodes

| Node | Purpose | Key Logic |
|------|---------|-----------|
| `process_input` | Interpret user commands | Handles start, quit, difficulty changes, skip, and answers |
| `generate_question` | Create new question | LLM generates question/answer JSON based on difficulty |
| `evaluate_answer` | Score user's answer | Text normalization + LLM-based nuanced evaluation |
| `find_source` | Get external source | Tavily MCP search for verification URL |
| `provide_feedback` | Build response | Constructs concise feedback with result + source |

### Scoring

| Result | Score | Description |
|--------|-------|-------------|
| correct | +1.0 | Essentially correct answer |
| partially_correct | +0.5 | Main idea correct, minor errors |
| partially_incorrect | +0.25 | Some relevant elements, mostly wrong |
| incorrect | +0 | Wrong answer |
| skipped | +0 | User skipped question |

## Usage

### Setup

```bash
# Install dependencies
pip install -e .

# Or with uv
uv pip install -e .

# Set up environment
cp .env.example .env
# Edit .env with your API keys
```

### Run

```bash
python quiz_main.py
```

### Commands

| Command | Action |
|---------|--------|
| `start` / `begin` | Start the quiz |
| `quit` / `exit` | End the quiz |
| `harder` | Increase difficulty |
| `easier` | Decrease difficulty |
| `skip` / `pass` | Skip current question |
| _any text_ | Answer the question |

### Example Session

```
Welcome to Pub Quiz! Type 'start' to begin.

> start

Question 1: What element has the chemical symbol Au?

> gold

Correct.
Source: https://en.wikipedia.org/wiki/Gold
Gold is a chemical element with symbol Au...
[Score: 1.0/1]

Question 2: In what year did the Berlin Wall fall?

> 1990

Partially correct. The full answer is 1989.
Source: https://en.wikipedia.org/wiki/Fall_of_the_Berlin_Wall
The Berlin Wall fell on November 9, 1989...
[Score: 1.5/2]

> harder

Difficulty set to hard.

Question 3: What is the Schwarzschild radius formula?

> skip

Skipped. The answer is rs = 2GM/c².
Source: https://en.wikipedia.org/wiki/Schwarzschild_radius
The Schwarzschild radius defines the radius of the event horizon...
[Score: 1.5/3]
```

## iOS App Integration

The `create_quiz_graph()` function returns a compiled StateGraph that can be wrapped in various backends:

### REST API (FastAPI)

```python
from fastapi import FastAPI
from graph import create_quiz_graph, get_initial_state

app = FastAPI()
sessions = {}  # Store quiz states by session ID

@app.post("/quiz/{session_id}/input")
async def process_input(session_id: str, user_input: str):
    if session_id not in sessions:
        sessions[session_id] = get_initial_state()
        sessions[session_id]["graph"] = await create_quiz_graph(mcp_tools)

    state = sessions[session_id]
    state["messages"].append(HumanMessage(content=user_input))
    result = await state["graph"].ainvoke(state)
    state.update(result)

    return {
        "response": state.get("pending_output", ""),
        "phase": state["phase"],
        "score": state["score"],
        "question_number": state["question_number"]
    }
```

### WebSocket

```python
@app.websocket("/quiz/ws")
async def quiz_websocket(websocket: WebSocket):
    await websocket.accept()
    state = get_initial_state()
    graph = await create_quiz_graph(mcp_tools)

    while True:
        user_input = await websocket.receive_text()
        state["messages"].append(HumanMessage(content=user_input))
        result = await graph.ainvoke(state)
        state.update(result)

        await websocket.send_json({
            "response": state.get("pending_output", ""),
            "phase": state["phase"],
            "score": state["score"]
        })
```

### State Serialization

The `QuizState` can be serialized to JSON for persistence:

```python
import json

# Save state
state_json = json.dumps({
    k: v for k, v in state.items()
    if k != "messages"  # Handle messages separately
})

# Messages need special handling for HumanMessage/AIMessage
messages_json = [
    {"type": m.__class__.__name__, "content": m.content}
    for m in state["messages"]
]
```

## File Structure

```
quiz_agent/
├── graph.py          # State schema, nodes, graph construction
├── quiz_main.py      # Terminal entry point, QuizOperator class
├── pyproject.toml    # Dependencies
├── .env.example      # Environment template
└── README.md         # This file
```

## Key Differences from WebOperator

| Aspect | WebOperator | QuizOperator |
|--------|-------------|--------------|
| State | Messages only | Rich quiz state (score, phase, etc.) |
| Session | Persistent MCP session for browser | Stateless Tavily calls |
| Flow | Free-form agent loop | Structured state machine |
| Tools | Browser automation | Search only |
| Output | Screenshots, DOM | Text feedback |

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `OPENAI_API_KEY` | Yes | OpenAI API key for GPT-4o-mini |
| `TAVILY_API_KEY` | Yes | Tavily API key for source lookup |

## Dependencies

- `langchain>=0.3.0` - LLM framework
- `langchain-openai>=0.2.0` - OpenAI integration
- `langgraph>=0.2.0` - State graph framework
- `langchain-mcp-adapters>=0.0.1` - MCP client adapters
- `python-dotenv>=1.0.0` - Environment loading
