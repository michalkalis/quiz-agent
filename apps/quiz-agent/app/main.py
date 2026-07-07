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
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
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
    logger.info(
        "Sentry initialized (env=%s)", os.environ.get("ENVIRONMENT", "development")
    )

from quiz_shared.database.chroma_client import ChromaDBClient
from quiz_shared.database.pgvector_client import PgvectorQuestionStore
from quiz_shared.database.sql_client import SQLClient
from quiz_shared.database.sync_pgvector_store import SyncPgvectorStore

from .config import get_settings
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
            project_root = os.path.abspath(
                os.path.join(os.path.dirname(__file__), "../../..")
            )
            chroma_path = os.path.join(project_root, "chroma_data")

        # Ensure directory exists
        os.makedirs(chroma_path, exist_ok=True)

        from .startup_checks import verify_chroma_path_on_volume

        verify_chroma_path_on_volume(chroma_path)

        chroma_client = ChromaDBClient(
            collection_name="quiz_questions", persist_directory=chroma_path
        )
        # ChromaDB is no longer consumed by any code path (#41 Session B) —
        # the client stays initialized only until Session C removes this
        # wiring and drops the dependency.
        logger.info("ChromaDB client initialized (unconsumed, using %s)", chroma_path)
    except Exception as e:
        logger.error("Failed to initialize ChromaDB: %s", e, exc_info=True)
        raise

    # Initialize the pgvector store — canonical for BOTH the voice-quiz read
    # path (#36 task 2.20) and the admin/feedback write surface (#41 D3).
    # DATABASE_URL is mandatory (#41 D6): no silent ChromaDB fallback.
    settings = get_settings()

    # #65: loudly flag a prod boot that ships App Attest inert (does not refuse).
    from .startup_checks import warn_if_insecure_production

    warn_if_insecure_production(settings, os.getenv("ENVIRONMENT"), logger)

    if not settings.database_url:
        raise ValueError(
            "DATABASE_URL environment variable is not set. Postgres (pgvector) "
            "is the canonical question store (#41 D6) — there is no fallback. "
            "Local dev: start the colima dev-stack Postgres (#73) and set "
            "DATABASE_URL in .env."
        )

    # Fly stores DATABASE_URL as libpq `postgres://`; the async read-path
    # needs the explicit `postgresql+asyncpg://` driver or create_async_engine
    # can't load the dialect and #36 voice read-path crashes at boot. The auth
    # engine already normalizes — reuse the same helper here (#60 flip gate).
    from .db.engine import normalize_async_url

    async_pgvector = PgvectorQuestionStore(
        database_url=normalize_async_url(settings.database_url)
    )
    retrieval_store = SyncPgvectorStore(async_pgvector)
    question_store = retrieval_store
    logger.info("Question store: PgvectorQuestionStore (canonical, read + write)")

    try:
        logger.info("Initializing SQL client...")
        # DATABASE_URL is the pgvector questions store (postgresql+asyncpg://,
        # async-only driver). The sync sqlite ratings store must not inherit
        # it — with DATABASE_URL set, startup died in create_all (MissingGreenlet).
        sql_client = SQLClient(
            database_url=os.getenv(
                "RATINGS_DATABASE_URL", "sqlite:///./data/ratings.db"
            )
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
        question_retriever = QuestionRetriever(question_store=retrieval_store)
        answer_evaluator = AnswerEvaluator()
        # Ratings persist in SQL only (#41 D1) — no question-store writes.
        feedback_service = FeedbackService(
            sql_client=sql_client,
            low_rating_threshold=2.5,
        )
        voice_transcriber = VoiceTranscriber()
        tts_service = TTSService()
        translation_service = TranslationService()
        # Persistent usage tracker on the auth Postgres (#60). Without
        # DATABASE_URL (plain local dev) usage limits are simply not enforced —
        # the dependents all guard a None tracker.
        auth_sessionmaker = None
        token_service = None
        refresh_store = None
        challenge_store = None
        app_attest_service = None
        apple_verifier = None
        apple_oauth_client = None
        apple_token_cipher = None
        if settings.database_url:
            from .db.engine import get_sessionmaker

            auth_sessionmaker = get_sessionmaker()
            usage_tracker = UsageTracker(auth_sessionmaker)
            # App Attest challenges need only the DB (no JWT secret), so the
            # endpoint is live wherever usage persistence is. The verification
            # gate that *uses* these challenges is flag-controlled (#60.12).
            from .auth.attest_challenge import build_challenge_store

            challenge_store = build_challenge_store(auth_sessionmaker, settings)
            # App Attest verification (#60.11/.12). Needs the app id ("TeamID.
            # BundleID") to check the rpId; without it the service stays None.
            # The bootstrap route gates on APP_ATTEST_REQUIRED: required+None is a
            # boot misconfiguration that must fail loud, not silently mint.
            if settings.app_attest_app_id:
                from .auth.app_attest import build_app_attest_service

                app_attest_service = build_app_attest_service(
                    auth_sessionmaker, challenge_store, settings
                )
                logger.info(
                    "App Attest verification enabled (env=%s, required=%s)",
                    settings.app_attest_environment,
                    settings.app_attest_required,
                )
            elif settings.app_attest_required:
                logger.error(
                    "APP_ATTEST_REQUIRED=on but APP_ATTEST_APP_ID is unset — "
                    "anon-bootstrap will fail safe (503) until the app id is set."
                )
            logger.info(
                "Services initialized (free limit: %d questions/month, persistent)",
                usage_tracker.monthly_limit,
            )
            # Auth token services (#60.4). Need the JWT secret too; without it the
            # /auth/* endpoints stay disabled (503) rather than minting tokens an
            # unconfigured secret can't verify. TokenService fails loud on a
            # too-short secret — a misconfigured prod must not boot half-secured.
            if settings.auth_jwt_secret:
                from .auth.refresh import build_refresh_store
                from .auth.tokens import build_token_service

                token_service = build_token_service(settings)
                refresh_store = build_refresh_store(auth_sessionmaker, settings)
                logger.info("Auth endpoints enabled (anon-bootstrap + refresh)")
                # Sign in with Apple (#61). /auth/apple needs the verifier
                # (id_token), the OAuth client (code→Apple refresh token), and the
                # at-rest cipher (F1/F2) — built only when the full key set is
                # present so the app still boots SIWA-disabled (the route 503s).
                if (
                    settings.apple_signin_client_id
                    and settings.apple_signin_team_id
                    and settings.apple_signin_key_id
                    and settings.apple_signin_private_key
                    and settings.apple_token_enc_key
                ):
                    from .auth.apple import build_apple_identity_verifier
                    from .auth.apple_oauth import build_apple_oauth_client
                    from .auth.apple_secrets import build_apple_token_cipher

                    apple_verifier = build_apple_identity_verifier(settings)
                    apple_oauth_client = build_apple_oauth_client(settings)
                    apple_token_cipher = build_apple_token_cipher(settings)
                    logger.info("Sign in with Apple enabled (/auth/apple)")
                elif settings.apple_signin_client_id:
                    logger.warning(
                        "Sign in with Apple partially configured — /auth/apple "
                        "disabled (503) until APPLE_SIGNIN_{CLIENT_ID,TEAM_ID,"
                        "KEY_ID,PRIVATE_KEY} and APPLE_TOKEN_ENC_KEY are all set."
                    )
            else:
                logger.warning(
                    "AUTH_JWT_SECRET not set — /auth/* disabled (503). "
                    "Production must set a >=64-char secret (#60)."
                )
        else:
            usage_tracker = None
            logger.warning(
                "DATABASE_URL not set — usage limits disabled (no daily_usage "
                "persistence). Production must set DATABASE_URL (#60)."
            )
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
            monitor = QuestionMonitor(session_factory=auth_sessionmaker)
            health = await monitor.check_health()
            if health.alerts:
                logger.warning("Question database health alerts: %s", health.alerts)
            app.state.question_monitor = monitor
        else:
            logger.warning("QuestionMonitor not available (import failed)")
            app.state.question_monitor = None
    except Exception as e:
        logger.warning("Question health monitor initialization failed: %s", e)
        app.state.question_monitor = None

    # Pre-generate static feedback audio.
    # Skippable (TTS_PREGENERATE=0) so environments without an empty audio cache
    # — notably CI, which starts cold and would otherwise block startup on live
    # OpenAI TTS calls — can boot fast. Feedback then falls back to on-demand.
    if os.getenv("TTS_PREGENERATE", "1") != "0":
        try:
            logger.info("Pre-generating static feedback audio...")
            await tts_service.pregenerate_static_feedback()
            logger.info("Static feedback audio ready")
        except Exception as e:
            logger.warning("Failed to pre-generate feedback audio: %s", e)
            logger.info("Feedback will be generated on-demand")
    else:
        logger.info("TTS_PREGENERATE=0 — skipping static feedback pre-generation")

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
    app.state.auth_sessionmaker = auth_sessionmaker
    app.state.token_service = token_service
    app.state.refresh_store = refresh_store
    app.state.challenge_store = challenge_store
    app.state.app_attest_service = app_attest_service
    app.state.apple_verifier = apple_verifier
    app.state.apple_oauth_client = apple_oauth_client
    app.state.apple_token_cipher = apple_token_cipher
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
    lifespan=lifespan,
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
    health_status = await monitor.check_health()
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
            "Client-agnostic design",
        ],
        "docs": "/docs",
        "health": "/api/v1/health",
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "app.main:app", host="0.0.0.0", port=8002, reload=True, log_level="info"
    )
