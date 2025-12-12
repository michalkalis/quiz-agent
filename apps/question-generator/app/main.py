"""Question Generator FastAPI application."""

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from .api.routes import router

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


@app.get("/")
async def root():
    """Root endpoint."""
    return {
        "name": "Quiz Question Generator API",
        "version": "0.1.0",
        "endpoints": {
            "generate": "POST /api/v1/generate",
            "import": "POST /api/v1/import",
            "approve": "POST /api/v1/questions/approve",
            "search": "GET /api/v1/questions/search",
            "duplicates": "POST /api/v1/questions/duplicates",
            "export_chatgpt": "GET /api/v1/export/chatgpt",
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
