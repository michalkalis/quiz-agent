#!/usr/bin/env python3
"""Pre-generate static feedback audio on server startup.

This script generates all static feedback phrases (Correct!, Wrong!, etc.)
as audio files to ensure instant playback with zero latency.

Called automatically in Docker CMD before starting the server.
"""

import asyncio
import sys
import os

# Add parent directory to path for imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.tts.service import TTSService


async def main():
    """Pre-generate all static feedback audio files."""
    print("\n" + "="*60)
    print("Pre-generating Static Feedback Audio")
    print("="*60 + "\n")

    # Check for OpenAI API key
    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key:
        print("⚠️  WARNING: OPENAI_API_KEY not set")
        print("   Static feedback will not be pre-generated")
        print("   Set OPENAI_API_KEY to enable TTS\n")
        return

    try:
        # Initialize TTS service
        tts = TTSService()

        # Pre-generate all static feedback
        await tts.pregenerate_static_feedback()

        # Show cache stats
        stats = tts.get_cache_stats()
        print(f"\nCache Statistics:")
        print(f"  Static feedback files: {stats['static_feedback_files']}")
        print(f"  Static cache size: {stats['static_size_mb']:.2f} MB")
        print(f"  Questions cached: {stats['questions_cached']}")
        print(f"  Total cache size: {stats['total_size_mb']:.2f} MB / {stats['max_size_mb']:.0f} MB\n")

        print("="*60)
        print("✅ Static feedback pre-generation complete!")
        print("="*60 + "\n")

    except Exception as e:
        print(f"\n❌ Error during pre-generation: {e}")
        import traceback
        traceback.print_exc()
        print("\nServer will continue without pre-generated feedback.")
        print("Feedback will be generated on-demand (slower first response).\n")


if __name__ == "__main__":
    asyncio.run(main())
