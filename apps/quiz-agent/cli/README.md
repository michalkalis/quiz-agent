# Quiz Agent Terminal Client

Interactive terminal client for the Quiz Agent API with beautiful formatting and natural language support.

## Features

- 🎨 **Rich Terminal UI** - Beautiful formatting with colors, panels, and tables
- 🤖 **Natural Language Input** - Say "Paris, but too easy" and the AI understands
- 📊 **Live Scoring** - See your score update in real-time
- ⚙️ **Adaptive Difficulty** - Say "harder" or "easier" to adjust mid-quiz
- 💬 **Smart Feedback** - AI parses your intent (answer, rating, preferences)
- ⏭️ **Skip Questions** - Type "skip" to move to the next question
- ⭐ **Rate Questions** - Provide feedback to improve content quality

## Prerequisites

1. **Quiz Agent API must be running**:
   ```bash
   cd apps/quiz-agent
   python -m app.main
   ```
   The API should be running at `http://localhost:8002`

2. **Dependencies installed**:
   ```bash
   cd apps/quiz-agent
   uv pip install -e .
   ```

3. **Activate virtual environment** (if using one):
   ```bash
   # From project root
   source .venv/bin/activate
   ```

## Quick Start

### Method 1: Direct Script

```bash
# Make sure virtual environment is activated
cd apps/quiz-agent/cli
python quiz.py
```

### Method 2: Module Import

```bash
# Make sure virtual environment is activated
cd apps/quiz-agent
python -m cli.terminal_ui
```

### Method 3: Using venv Python directly

```bash
# From project root
.venv/bin/python apps/quiz-agent/cli/quiz.py
```

## Usage

### Basic Flow

1. **Start the client** - Run the script
2. **Connect to API** - Automatic health check
3. **Configure quiz**:
   - Number of questions (default: 10)
   - Difficulty (easy/medium/hard)
   - Category (optional)
4. **Answer questions** naturally
5. **View results** at the end

### Example Session

```
🎯 Quiz Agent Terminal

Welcome to the AI-powered quiz experience!
...

✅ Connected to Quiz Agent API

Quiz Configuration

Number of questions [10]: 5
Starting difficulty [medium]: medium
Category (optional):

✅ Session created: sess_abc123
📝 Questions: 5 | Difficulty: medium

┌─ Question 1/5 ───────────────────────────────┐
│                                              │
│ What is the capital of France?              │
│                                              │
│ Topic: Geography | Difficulty: easy | Type: text │
└──────────────────────────────────────────────┘

Your answer: Paris

┌─ Result ─────────────────────────────────────┐
│ ✅ Correct!                                   │
│                                              │
│ Your answer: Paris                           │
│ Correct answer: Paris                        │
│ Points: +1.0                                 │
└──────────────────────────────────────────────┘

Score: 1.0 / 1 questions (100%)
```

### Natural Language Examples

**Answer with feedback:**
```
Your answer: Paris, but this is too easy
```
AI understands: Answer = "Paris", Rating = 1, Difficulty = increase

**Answer with preference:**
```
Your answer: London, no more geography please
```
AI understands: Answer = "London", Avoid topic = "geography"

**Answer with rating:**
```
Your answer: Shakespeare, great question!
```
AI understands: Answer = "Shakespeare", Rating = 5

**Commands:**
```
Your answer: skip
Your answer: harder
Your answer: easier
Your answer: quit
```

## Command Reference

| Input | Action |
|-------|--------|
| `<answer>` | Submit your answer |
| `skip` | Skip current question (no points) |
| `harder` | Increase difficulty for next question |
| `easier` | Decrease difficulty for next question |
| `quit` / `exit` | End quiz and show results |

## Natural Language Features

The AI input parser understands:

### Combined Intents
- **Answer + Rating**: "Paris, too easy" → Answer + negative rating
- **Answer + Preference**: "Rome, I like history" → Answer + prefer history
- **Answer + Feedback**: "London, great question!" → Answer + positive rating

### Sentiment Analysis
- Positive: "great", "love", "excellent" → Rating: 5
- Negative: "too easy", "boring", "bad" → Rating: 1

### Topic Preferences
- Include: "I like science" → More science questions
- Exclude: "no more geography" → Avoid geography

## Advanced Options

### Custom API URL

```bash
python quiz.py --api-url http://your-server:8002/api/v1
```

### Using as a Library

```python
from cli.terminal_ui import QuizTerminalUI

ui = QuizTerminalUI(api_url="http://localhost:8002/api/v1")
ui.run()
```

## Troubleshooting

### "Cannot connect to Quiz Agent API"

**Solution**: Make sure the API is running:
```bash
cd apps/quiz-agent
python -m app.main
```

Verify it's accessible:
```bash
curl http://localhost:8002/api/v1/health
```

### "ImportError: No module named 'rich'"

**Solution**: Activate the virtual environment first:
```bash
# From project root
source .venv/bin/activate

# Then run the CLI
cd apps/quiz-agent/cli
python quiz.py
```

Or install dependencies in your current Python environment:
```bash
cd apps/quiz-agent
uv pip install -e .
```

### Session Expires

Sessions expire after 30 minutes of inactivity. If you see an error about session not found, just start a new quiz.

## Architecture

```
Terminal Client
    ↓ HTTP/REST
Quiz Agent API (port 8002)
    ↓ Query
ChromaDB (questions) + PostgreSQL (ratings)
```

## Related

- **Quiz Agent API**: `apps/quiz-agent/` - Backend service
- **Question Generator**: `apps/question-generator/` - Admin tool for content
- **Product Spec**: `PRODUCT_SPEC.md` - Full feature documentation

## License

MIT
