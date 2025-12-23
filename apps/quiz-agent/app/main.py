"""Quiz Agent API - Client-agnostic quiz service.

AI-powered quiz agent with natural language understanding,
RAG-based question retrieval, and nuanced answer evaluation.

Features:
- Natural language input parsing (AI agent core)
- Voice transcription with Whisper API
- Semantic question retrieval with RAG
- Multi-tier answer evaluation
- User rating and feedback system
- Multiplayer-ready architecture
- Client-agnostic (iOS, TV, terminal, web)

Run with: uvicorn app.main:app --reload --port 8002
"""

from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../..", "packages/shared"))

# Load environment variables from .env files
try:
    from dotenv import load_dotenv
    # Try multiple locations: current dir, parent dirs, and project root
    base_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.join(base_dir, "../..")
    load_dotenv(os.path.join(project_root, ".env"))  # Project root .env
    load_dotenv(os.path.join(base_dir, "../../.env"))  # Also check parent
    load_dotenv()  # Current directory .env (overrides others)
except ImportError:
    # python-dotenv not available, skip .env loading
    pass

from quiz_shared.database.chroma_client import ChromaDBClient
from quiz_shared.database.sql_client import SQLClient

from .session.manager import SessionManager
from .input.parser import InputParser
from .retrieval.question_retriever import QuestionRetriever
from .evaluation.evaluator import AnswerEvaluator
from .rating.feedback import FeedbackService
from .voice.transcriber import VoiceTranscriber
from .tts.service import TTSService
from .api import rest, admin


# Global service instances
session_manager: SessionManager = None
chroma_client: ChromaDBClient = None
sql_client: SQLClient = None
tts_service: TTSService = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan manager.

    Handles startup and shutdown tasks:
    - Initialize services
    - Start background cleanup
    - Graceful shutdown
    """
    global session_manager, chroma_client, sql_client, tts_service

    print("Starting Quiz Agent API...")
    sys.stdout.flush()  # Ensure output is visible

    # Check for required environment variables
    openai_api_key = os.getenv("OPENAI_API_KEY")
    if not openai_api_key:
        raise ValueError(
            "OPENAI_API_KEY environment variable is not set. "
            "Please set it before starting the server:\n"
            "  export OPENAI_API_KEY='your-api-key-here'\n"
            "Or create a .env file with: OPENAI_API_KEY=your-api-key-here"
        )

    # Validate working directory
    if not os.path.exists("app"):
        raise ValueError(
            "Server must be run from apps/quiz-agent/ directory.\n"
            f"Current directory: {os.getcwd()}\n"
            "Please run: cd apps/quiz-agent && python -m app.main"
        )
    print(f"✓ Working directory: {os.getcwd()}")
    sys.stdout.flush()

    # Ensure data directory exists
    data_dir = "./data"
    os.makedirs(data_dir, exist_ok=True)
    print("✓ Data directory ready")
    sys.stdout.flush()

    # Initialize database clients
    try:
        print("Initializing ChromaDB client...")
        sys.stdout.flush()
        # Use shared ChromaDB at project root (same as question-generator web UI)
        project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
        chroma_path = os.path.join(project_root, "chroma_data")
        chroma_client = ChromaDBClient(
            collection_name="quiz_questions",
            persist_directory=chroma_path
        )
        print(f"✓ ChromaDB client initialized (using {chroma_path})")
        sys.stdout.flush()
    except Exception as e:
        print(f"ERROR: Failed to initialize ChromaDB: {e}")
        import traceback
        traceback.print_exc()
        raise

    try:
        print("Initializing SQL client...")
        sys.stdout.flush()
        sql_client = SQLClient(
            database_url=os.getenv("DATABASE_URL", "sqlite:///./data/ratings.db")
        )
        print("✓ SQL client initialized")
        sys.stdout.flush()
    except Exception as e:
        print(f"ERROR: Failed to initialize SQL client: {e}")
        import traceback
        traceback.print_exc()
        raise

    # Initialize services
    try:
        print("Initializing services...")
        sys.stdout.flush()
        session_manager = SessionManager(cleanup_interval=300)  # 5 min
        input_parser = InputParser()
        question_retriever = QuestionRetriever(chroma_client=chroma_client)
        answer_evaluator = AnswerEvaluator()
        feedback_service = FeedbackService(
            chroma_client=chroma_client,
            sql_client=sql_client,
            low_rating_threshold=2.5
        )
        voice_transcriber = VoiceTranscriber()
        tts_service = TTSService()
        print("✓ Services initialized")
        sys.stdout.flush()
    except Exception as e:
        print(f"ERROR: Failed to initialize services: {e}")
        import traceback
        traceback.print_exc()
        raise

    # Pre-generate static feedback audio
    try:
        print("Pre-generating static feedback audio...")
        sys.stdout.flush()
        await tts_service.pregenerate_static_feedback()
        print("✓ Static feedback audio ready")
        sys.stdout.flush()
    except Exception as e:
        print(f"WARNING: Failed to pre-generate feedback audio: {e}")
        print("Feedback will be generated on-demand")
        sys.stdout.flush()

    # Inject dependencies into REST API
    rest.init_dependencies(
        sm=session_manager,
        ip=input_parser,
        qr=question_retriever,
        ae=answer_evaluator,
        fs=feedback_service,
        vt=voice_transcriber,
        tts=tts_service,
        cc=chroma_client
    )
    # Inject dependencies into Admin API
    admin.init_dependencies(cc=chroma_client)
    print("✓ API dependencies configured")

    # Start background tasks
    await session_manager.start_cleanup()
    print("✓ Background cleanup started")

    print("\n" + "="*50)
    print("Quiz Agent API is ready!")
    print("API Documentation: http://localhost:8002/docs")
    print("Health Check: http://localhost:8002/api/v1/health")
    print("="*50 + "\n")

    yield

    # Shutdown
    print("\nShutting down Quiz Agent API...")
    await session_manager.stop_cleanup()
    print("✓ Cleanup stopped")


# Create FastAPI app
app = FastAPI(
    title="Quiz Agent API",
    description=(
        "AI-powered quiz service with natural language understanding. "
        "Client-agnostic design for iOS, TV, terminal, and web clients."
    ),
    version="1.0.0",
    lifespan=lifespan
)

# CORS middleware for web clients
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Configure appropriately for production
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include API routes
app.include_router(rest.router)
app.include_router(admin.router)


# Root endpoint
@app.get("/")
async def root():
    """Root endpoint with API info."""
    return {
        "service": "Quiz Agent API",
        "version": "1.0.0",
        "description": "AI-powered quiz service with natural language understanding",
        "features": [
            "Natural language input parsing",
            "Voice transcription (Whisper API)",
            "RAG-based question retrieval",
            "Nuanced answer evaluation",
            "User ratings and feedback",
            "Multiplayer support",
            "Client-agnostic design"
        ],
        "docs": "/docs",
        "health": "/api/v1/health"
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "app.main:app",
        host="0.0.0.0",
        port=8002,
        reload=True,
        log_level="info"
    )
