# Quiz Agent API

AI-powered quiz service with natural language understanding. Client-agnostic design for iOS, TV, terminal, and web clients.

## Features

- **Natural Language Input**: AI-powered parsing of user input (e.g., "Paris, but too easy")
- **Voice Transcription**: Whisper API integration for hands-free quiz interaction
- **RAG-Based Retrieval**: Semantic search for intelligent question selection
- **Nuanced Evaluation**: Fair answer evaluation with partial credit
- **User Ratings**: 1-5 rating system with feedback
- **Multiplayer Ready**: Session-based architecture supporting multiple participants
- **Client-Agnostic**: Platform-independent JSON responses

## Quick Start

### Installation

```bash
# From workspace root
uv pip install -e apps/quiz-agent
```

### Running the API

```bash
cd apps/quiz-agent
uvicorn app.main:app --reload --port 8002
```

Or run directly:

```bash
python -m app.main
```

### API Documentation

Once running, visit:
- Interactive docs: http://localhost:8002/docs
- Health check: http://localhost:8002/api/v1/health

## API Usage Guide

### 1. Create Session

```bash
POST /api/v1/sessions
Content-Type: application/json

{
  "max_questions": 10,
  "difficulty": "medium",
  "user_id": "user_123",
  "mode": "single",
  "category": "adults",
  "ttl_minutes": 30
}
```

Response:
```json
{
  "session_id": "sess_abc123def456",
  "mode": "single",
  "phase": "idle",
  "max_questions": 10,
  "current_difficulty": "medium",
  "category": "adults",
  "participants": [
    {
      "participant_id": "p_12345678",
      "user_id": "user_123",
      "display_name": "user_123",
      "score": 0.0,
      "answered_count": 0,
      "is_host": true,
      "is_ready": true
    }
  ],
  "expires_at": "2025-12-12T15:30:00",
  "created_at": "2025-12-12T15:00:00"
}
```

### 2. Start Quiz

```bash
POST /api/v1/sessions/{session_id}/start
Content-Type: application/json

{}
```

Response:
```json
{
  "success": true,
  "message": "Quiz started",
  "session": { ... },
  "current_question": {
    "id": "q_abc123",
    "question": "What is the capital of France?",
    "type": "text",
    "possible_answers": null,
    "difficulty": "easy",
    "topic": "Geography",
    "category": "adults"
  },
  "evaluation": null,
  "feedback_received": []
}
```

### 3. Submit Input (AI-Powered)

This is the core AI agent feature. Submit natural language and the system automatically parses it.

**Example 1: Simple Answer**
```bash
POST /api/v1/sessions/{session_id}/input
Content-Type: application/json

{
  "input": "Paris"
}
```

**Example 2: Answer + Feedback**
```bash
{
  "input": "Paris, but this question is too easy"
}
```

**Example 3: Answer + Difficulty Change**
```bash
{
  "input": "London, make it harder please"
}
```

**Example 4: Skip + Topic Preference**
```bash
{
  "input": "skip, no more geography questions"
}
```

Response:
```json
{
  "success": true,
  "message": "Input processed",
  "session": {
    "session_id": "sess_abc123",
    "phase": "asking",
    "participants": [
      {
        "participant_id": "p_12345678",
        "score": 1.0,
        "answered_count": 1
      }
    ]
  },
  "current_question": {
    "id": "q_xyz789",
    "question": "What is the largest planet in our solar system?",
    "type": "text",
    "difficulty": "medium"
  },
  "evaluation": {
    "user_answer": "Paris",
    "result": "correct",
    "points": 1.0,
    "correct_answer": "Paris"
  },
  "feedback_received": [
    "answer: correct",
    "difficulty: hard"
  ]
}
```

### 4. Rate Question

```bash
POST /api/v1/sessions/{session_id}/rate
Content-Type: application/json

{
  "rating": 5,
  "feedback_text": "Great question!",
  "participant_id": "p_12345678"
}
```

Response:
```json
{
  "success": true,
  "message": "Rating submitted successfully"
}
```

### 5. Get Session State

```bash
GET /api/v1/sessions/{session_id}
```

### 6. Delete Session

```bash
DELETE /api/v1/sessions/{session_id}
```

### 7. Voice Transcription

Transcribe audio to text using Whisper API:

```bash
POST /api/v1/voice/transcribe
Content-Type: multipart/form-data

# Upload audio file
curl -X POST http://localhost:8002/api/v1/voice/transcribe \
  -F "audio=@answer.mp3"
```

Response:
```json
{
  "success": true,
  "text": "Paris",
  "language": "en",
  "filename": "answer.mp3"
}
```

**Supported formats**: mp3, mp4, mpeg, mpga, m4a, wav, webm, ogg
**Max file size**: 25 MB

### 8. Voice Submit (One-Step)

Transcribe audio and submit to quiz in one request:

```bash
POST /api/v1/voice/submit/{session_id}
Content-Type: multipart/form-data

# Upload audio with optional participant_id
curl -X POST http://localhost:8002/api/v1/voice/submit/sess_abc123 \
  -F "audio=@answer.mp3" \
  -F "participant_id=p_12345678"
```

Response: Same as `/sessions/{id}/input` endpoint, with transcribed text processed by AI parser.

**How it works**:
1. Audio → Whisper API → Text transcription
2. Text → InputParser → Intent extraction (answer, rating, preferences)
3. Evaluation → Next question

Perfect for:
- Voice-based UIs (TV apps, smart speakers)
- Accessibility features
- Hands-free quiz interaction

## Client Integration Examples

### iOS (Swift)

```swift
import Foundation

struct QuizSession: Codable {
    let session_id: String
    let mode: String
    let phase: String
    // ... other fields
}

struct InputResponse: Codable {
    let success: Bool
    let message: String
    let session: QuizSession
    let current_question: Question?
    let evaluation: Evaluation?
    let feedback_received: [String]
}

class QuizClient {
    let baseURL = "http://localhost:8002/api/v1"

    func createSession() async throws -> QuizSession {
        let url = URL(string: "\(baseURL)/sessions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "max_questions": 10,
            "difficulty": "medium",
            "mode": "single"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(QuizSession.self, from: data)
    }

    func submitInput(sessionId: String, input: String) async throws -> InputResponse {
        let url = URL(string: "\(baseURL)/sessions/\(sessionId)/input")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["input": input]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(InputResponse.self, from: data)
    }
}
```

### Terminal (Python)

```python
import requests

class QuizClient:
    def __init__(self, base_url="http://localhost:8002/api/v1"):
        self.base_url = base_url
        self.session_id = None

    def create_session(self, max_questions=10, difficulty="medium"):
        response = requests.post(
            f"{self.base_url}/sessions",
            json={
                "max_questions": max_questions,
                "difficulty": difficulty,
                "mode": "single"
            }
        )
        response.raise_for_status()
        data = response.json()
        self.session_id = data["session_id"]
        return data

    def start_quiz(self):
        response = requests.post(
            f"{self.base_url}/sessions/{self.session_id}/start",
            json={}
        )
        response.raise_for_status()
        return response.json()

    def submit_input(self, user_input):
        response = requests.post(
            f"{self.base_url}/sessions/{self.session_id}/input",
            json={"input": user_input}
        )
        response.raise_for_status()
        return response.json()

    def rate_question(self, rating, feedback=None):
        response = requests.post(
            f"{self.base_url}/sessions/{self.session_id}/rate",
            json={
                "rating": rating,
                "feedback_text": feedback
            }
        )
        response.raise_for_status()
        return response.json()

# Usage
client = QuizClient()
session = client.create_session()
result = client.start_quiz()

print(f"Q: {result['current_question']['question']}")
answer = input("Your answer: ")

result = client.submit_input(answer)
print(f"Result: {result['evaluation']['result']}")
print(f"Score: {result['evaluation']['points']}")
```

### TV App (JavaScript)

```javascript
class QuizClient {
    constructor(baseURL = "http://localhost:8002/api/v1") {
        this.baseURL = baseURL;
        this.sessionId = null;
    }

    async createSession(options = {}) {
        const response = await fetch(`${this.baseURL}/sessions`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
                max_questions: options.maxQuestions || 10,
                difficulty: options.difficulty || "medium",
                mode: options.mode || "single"
            })
        });

        const data = await response.json();
        this.sessionId = data.session_id;
        return data;
    }

    async startQuiz() {
        const response = await fetch(
            `${this.baseURL}/sessions/${this.sessionId}/start`,
            {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({})
            }
        );
        return await response.json();
    }

    async submitInput(input) {
        const response = await fetch(
            `${this.baseURL}/sessions/${this.sessionId}/input`,
            {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ input })
            }
        );
        return await response.json();
    }
}

// Usage
const client = new QuizClient();
const session = await client.createSession();
const result = await client.startQuiz();

console.log(`Question: ${result.current_question.question}`);
// Display question on TV screen
// Get user input via remote control
const userInput = getUserInputFromRemote();
const evalResult = await client.submitInput(userInput);
```

## Natural Language Processing

The `/input` endpoint uses AI to understand complex user input:

| User Input | Parsed Intents |
|------------|----------------|
| `"Paris"` | Answer: Paris |
| `"Paris, too easy"` | Answer: Paris, Rating: 1 |
| `"London, make it harder"` | Answer: London, Difficulty: hard |
| `"skip, no more geography"` | Skip, Avoid topic: geography |
| `"Rome, I like history questions"` | Answer: Rome, Prefer topic: history |

## Multiplayer Support

### Create Multiplayer Session

```bash
POST /api/v1/sessions
{
  "mode": "multiplayer",
  "max_questions": 15
}
```

### Add Participants

```bash
POST /api/v1/sessions/{session_id}/participants
{
  "display_name": "Player 2",
  "user_id": "user_456"
}
```

### Submit Input with Participant ID

```bash
POST /api/v1/sessions/{session_id}/input
{
  "input": "Paris",
  "participant_id": "p_12345678"
}
```

## Environment Variables

- `OPENAI_API_KEY`: Required for AI features
- `DATABASE_URL`: Optional (defaults to SQLite: `sqlite:///./data/ratings.db`)

## Architecture

```
Quiz Agent API
├── Session Manager (in-memory with TTL)
├── Input Parser (AI-powered NLP)
├── Question Retriever (RAG/ChromaDB)
├── Answer Evaluator (two-tier: text match + LLM)
└── Feedback Service (dual storage: ChromaDB + SQL)
```

## Related Services

- **Question Generator** (port 8001): Admin tool for generating questions
- **Shared Library**: Common models and utilities

## License

MIT
