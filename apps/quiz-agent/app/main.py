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

import logging
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

import os
import sentry_sdk

# Load environment variables from .env files
try:
    from dotenv import load_dotenv
    # Repo root is 3 levels up from app/main.py: app/ → quiz-agent/ → apps/ → repo root
    base_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.join(base_dir, "../../..")
    load_dotenv(os.path.join(repo_root, ".env"))  # Repo root .env
    load_dotenv()  # CWD .env (overrides if present)
except ImportError:
    # python-dotenv not available, skip .env loading
    pass

# Setup logging before anything else
from .logging_config import setup_logging
setup_logging()
logger = logging.getLogger(__name__)

# Initialize Sentry (no-op if SENTRY_DSN is not set)
sentry_dsn = os.environ.get("SENTRY_DSN")
if sentry_dsn:
    sentry_sdk.init(
        dsn=sentry_dsn,
        traces_sample_rate=0.1,
        environment=os.environ.get("ENVIRONMENT", "development"),
    )
    logger.info("Sentry initialized (env=%s)", os.environ.get("ENVIRONMENT", "development"))

from quiz_shared.database.chroma_client import ChromaDBClient
from quiz_shared.database.sql_client import SQLClient

from .session.manager import SessionManager
from .input.parser import InputParser
from .retrieval.question_retriever import QuestionRetriever
from .evaluation.evaluator import AnswerEvaluator
from .rating.feedback import FeedbackService
from .voice.transcriber import VoiceTranscriber
from .tts.service import TTSService
from .translation import TranslationService
from .usage.tracker import UsageTracker
from .api import rest, admin
from .quiz.flow import QuizFlowService

try:
    from .monitoring.question_monitor import QuestionMonitor
except ImportError:
    QuestionMonitor = None

from .rate_limit import limiter

# Global service instances
session_manager: SessionManager = None
chroma_client: ChromaDBClient = None
sql_client: SQLClient = None
tts_service: TTSService = None
translation_service: TranslationService = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan manager.

    Handles startup and shutdown tasks:
    - Initialize services
    - Start background cleanup
    - Graceful shutdown
    """
    global session_manager, chroma_client, sql_client, tts_service, translation_service

    logger.info("Starting Quiz Agent API...")

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
    logger.info("Working directory: %s", os.getcwd())

    # Ensure data directory exists
    data_dir = "./data"
    os.makedirs(data_dir, exist_ok=True)
    logger.info("Data directory ready")

    # Initialize database clients
    try:
        logger.info("Initializing ChromaDB client...")

        # Use CHROMA_PATH env var if set (for production), otherwise use project root (for local dev)
        chroma_path = os.getenv("CHROMA_PATH")
        if not chroma_path:
            # Local development: use shared ChromaDB at project root
            project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
            chroma_path = os.path.join(project_root, "chroma_data")

        # Ensure directory exists
        os.makedirs(chroma_path, exist_ok=True)

        from .startup_checks import verify_chroma_path_on_volume
        verify_chroma_path_on_volume(chroma_path)

        chroma_client = ChromaDBClient(
            collection_name="quiz_questions",
            persist_directory=chroma_path
        )
        question_store = chroma_client.store
        logger.info("ChromaDB client + QuestionStore initialized (using %s)", chroma_path)
    except Exception as e:
        logger.error("Failed to initialize ChromaDB: %s", e, exc_info=True)
        raise

    try:
        logger.info("Initializing SQL client...")
        sql_client = SQLClient(
            database_url=os.getenv("DATABASE_URL", "sqlite:///./data/ratings.db")
        )
        logger.info("SQL client initialized")
    except Exception as e:
        logger.error("Failed to initialize SQL client: %s", e, exc_info=True)
        raise

    # Initialize services
    try:
        logger.info("Initializing services...")
        session_manager = SessionManager(cleanup_interval=300, sql_client=sql_client)
        input_parser = InputParser()
        question_retriever = QuestionRetriever(question_store=question_store)
        answer_evaluator = AnswerEvaluator()
        feedback_service = FeedbackService(
            question_store=question_store,
            sql_client=sql_client,
            low_rating_threshold=2.5
        )
        voice_transcriber = VoiceTranscriber()
        tts_service = TTSService()
        translation_service = TranslationService()
        usage_tracker = UsageTracker()
        logger.info("Services initialized (free limit: %d questions/day)", usage_tracker.daily_limit)
    except Exception as e:
        logger.error("Failed to initialize services: %s", e, exc_info=True)
        raise

    # Reload persisted sessions (survives fly deploy restarts)
    try:
        reloaded = session_manager.reload_active_sessions()
        if reloaded:
            logger.info("Restored %d sessions from previous run", reloaded)
    except Exception as e:
        logger.warning("Failed to reload sessions: %s", e)

    # Question health check on startup
    try:
        if QuestionMonitor is not None:
            monitor = QuestionMonitor(chroma_client=chroma_client.client)
            health = monitor.check_health()
            if health.alerts:
                logger.warning("Question database health alerts: %s", health.alerts)
            app.state.question_monitor = monitor
        else:
            logger.warning("QuestionMonitor not available (import failed)")
            app.state.question_monitor = None
    except Exception as e:
        logger.warning("Question health monitor initialization failed: %s", e)
        app.state.question_monitor = None

    # Pre-generate static feedback audio
    try:
        logger.info("Pre-generating static feedback audio...")
        await tts_service.pregenerate_static_feedback()
        logger.info("Static feedback audio ready")
    except Exception as e:
        logger.warning("Failed to pre-generate feedback audio: %s", e)
        logger.info("Feedback will be generated on-demand")

    # Store services on app.state for FastAPI Depends() injection
    app.state.session_manager = session_manager
    app.state.question_retriever = question_retriever
    app.state.feedback_service = feedback_service
    app.state.voice_transcriber = voice_transcriber
    app.state.tts_service = tts_service
    app.state.translation_service = translation_service
    app.state.chroma_client = chroma_client
    app.state.question_store = question_store
    app.state.usage_tracker = usage_tracker
    app.state.quiz_flow = QuizFlowService(
        session_manager=session_manager,
        input_parser=input_parser,
        question_retriever=question_retriever,
        answer_evaluator=answer_evaluator,
        tts_service=tts_service,
        usage_tracker=usage_tracker,
        translation_service=translation_service,
    )
    logger.info("API dependencies configured")

    # Start background tasks
    await session_manager.start_cleanup()
    logger.info("Background cleanup started")

    logger.info("Quiz Agent API is ready! Docs: /docs | Health: /api/v1/health")

    yield

    # Shutdown
    logger.info("Shutting down Quiz Agent API...")
    await session_manager.stop_cleanup()
    logger.info("Cleanup stopped")


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

# Register rate limiter
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# CORS middleware for web clients (iOS native client doesn't use CORS)
cors_origins = os.getenv("CORS_ORIGINS", "http://localhost:3000")
app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in cors_origins.split(",") if o.strip()],
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allow_headers=["Content-Type", "X-Admin-Key", "Authorization"],
)

# Include API routes
app.include_router(rest.router)
app.include_router(admin.router)


@app.get("/api/v1/admin/health")
async def get_question_health():
    """Get question database health status."""
    monitor = getattr(app.state, "question_monitor", None)
    if not monitor:
        return {"error": "Health monitor not initialized"}
    health_status = monitor.check_health()
    return health_status.to_dict()


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
