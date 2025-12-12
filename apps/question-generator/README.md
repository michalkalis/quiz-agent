# Question Generator API

Admin tool for generating and curating quiz questions with RAG-based duplicate detection.

## Features

- ✅ LLM-powered question generation (batches of 1-50)
- ✅ Enhanced prompt template with quality examples
- ✅ RAG-based duplicate detection (cosine similarity > 0.85)
- ✅ Semantic search for existing questions
- ✅ Import from ChatGPT JSON output
- ✅ FastAPI REST endpoints
- ✅ Multi-type support (text, text_multichoice)

## Quick Start

### Install Dependencies

```bash
# From project root
cd apps/question-generator
uv pip install -e .
```

### Set Environment Variables

```bash
export OPENAI_API_KEY=your_key_here
```

### Run Server

```bash
# From apps/question-generator
python -m uvicorn app.main:app --reload --port 8001
```

Or:

```bash
python app/main.py
```

API will be available at: `http://localhost:8001`

Interactive docs at: `http://localhost:8001/docs`

## API Endpoints

### Generate Questions

```bash
POST /api/v1/generate
{
  "count": 10,
  "difficulty": "medium",
  "topics": ["science", "history"],
  "categories": ["adults"],
  "type": "text"
}
```

### Import Questions (from ChatGPT)

```bash
POST /api/v1/import
{
  "questions": [
    {
      "question": "What is...",
      "correct_answer": "...",
      "topic": "Science",
      "difficulty": "medium",
      "category": "adults"
    }
  ],
  "source": "chatgpt"
}
```

### Check Duplicates

```bash
POST /api/v1/questions/duplicates?question_text=What is the capital of France?&threshold=0.85
```

### Approve Questions

```bash
POST /api/v1/questions/approve
{
  "question_ids": ["temp_abc123"],
  "force": false
}
```

### Search Questions

```bash
GET /api/v1/questions/search?query=space questions&difficulty=medium&limit=10
```

### Export Prompt for ChatGPT

```bash
GET /api/v1/export/chatgpt?count=10&difficulty=medium&topics=science
```

## Manual ChatGPT Workflow

1. Get prompt: `GET /api/v1/export/chatgpt`
2. Copy prompt to ChatGPT
3. Generate questions in ChatGPT
4. Copy JSON output
5. Import: `POST /api/v1/import`
6. Review and approve: `POST /api/v1/questions/approve`

## Architecture

```
question-generator/
├── app/
│   ├── main.py              # FastAPI application
│   ├── generation/
│   │   ├── generator.py     # LLM question generation
│   │   ├── prompt_builder.py # Dynamic prompt construction
│   │   ├── storage.py       # ChromaDB integration
│   │   └── examples.py      # Quality examples
│   └── api/
│       ├── routes.py        # API endpoints
│       └── schemas.py       # Request/response models
├── prompts/
│   └── question_generation.md  # Enhanced prompt template
└── README.md
```

## Next Steps

- Add Gradio UI for visual review workflow
- Implement pending review storage
- Add analytics dashboard
- Batch operations for large datasets
