"""Question Generator FastAPI application."""

import os
import sys

# Load environment variables from .env files
try:
    from dotenv import load_dotenv
    # Try multiple locations: current dir, parent dirs, and project root
    base_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.join(base_dir, "../../..")
    load_dotenv(os.path.join(project_root, ".env"))  # Project root .env
    load_dotenv(os.path.join(base_dir, "../../.env"))  # Also check parent
    load_dotenv()  # Current directory .env (overrides others)
except ImportError:
    # python-dotenv not available, skip .env loading
    pass

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from .api.routes import router
from .web.routes import router as web_router

# Create FastAPI app
app = FastAPI(
    title="Quiz Question Generator",
    description="Admin tool for generating and curating quiz questions with RAG-based duplicate detection",
    version="0.1.0"
)

# Add CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Configure appropriately for production
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include API routes
app.include_router(router)
app.include_router(web_router)


@app.get("/")
async def root():
    """Root endpoint."""
    return {
        "name": "Quiz Question Generator API",
        "version": "0.1.0",
        "web_ui": "http://localhost:8001/web",
        "endpoints": {
            "web_ui": "GET /web - Question management web interface",
            "generate": "POST /api/v1/generate",
            "generate_advanced": "POST /api/v1/generate/advanced",
            "import": "POST /api/v1/import",
            "approve": "POST /api/v1/questions/approve",
            "search": "GET /api/v1/questions/search",
            "duplicates": "POST /api/v1/questions/duplicates",
            "export_chatgpt": "GET /api/v1/export/chatgpt",
            "review_pending": "GET /api/v1/reviews/pending",
            "review_submit": "POST /api/v1/reviews/submit",
            "review_stats": "GET /api/v1/reviews/stats",
            "docs": "/docs"
        }
    }


@app.get("/health")
async def health():
    """Health check endpoint."""
    return {"status": "healthy"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8001)
