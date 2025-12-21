"""TTS audio caching system with LRU eviction.

Implements 3-tier caching:
1. Static feedback (pre-generated, never evicted)
2. Question audio (LRU cache, max 100MB)
3. Dynamic generation (fallback)
"""

import hashlib
import time
import os
from pathlib import Path
from typing import Optional, Dict, Tuple
from dataclasses import dataclass
import json


@dataclass
class CacheEntry:
    """Cache entry metadata."""
    path: Path
    last_access: float
    size_bytes: int
    voice: str


class TTSCache:
    """LRU cache for TTS audio files.

    Features:
    - Hash-based keys (SHA256 of text + voice)
    - File-based storage with metadata
    - LRU eviction when max size exceeded
    - Separate static and dynamic caches

    Cache structure:
    /data/tts_cache/
    ├── static/              # Pre-generated feedback (never evicted)
    │   ├── feedback_correct_0.opus
    │   ├── feedback_incorrect_0.opus
    │   └── ...
    ├── questions/           # LRU cache for questions
    │   ├── a3f8e9c2d1b4.opus
    │   ├── b7c4d5a8e9f1.opus
    │   └── ...
    └── metadata.json        # Cache metadata
    """

    def __init__(
        self,
        cache_dir: str = "./data/tts_cache",
        max_size_mb: int = 100
    ):
        """Initialize TTS cache.

        Args:
            cache_dir: Directory for cache storage
            max_size_mb: Maximum cache size in megabytes
        """
        self.cache_dir = Path(cache_dir)
        self.max_size_bytes = max_size_mb * 1024 * 1024

        # Create cache directories
        self.static_dir = self.cache_dir / "static"
        self.questions_dir = self.cache_dir / "questions"
        self.static_dir.mkdir(parents=True, exist_ok=True)
        self.questions_dir.mkdir(parents=True, exist_ok=True)

        # LRU cache metadata (for questions only)
        self.lru: Dict[str, CacheEntry] = {}
        self.metadata_path = self.cache_dir / "metadata.json"

        # Load existing metadata
        self._load_metadata()

    def _load_metadata(self):
        """Load cache metadata from disk."""
        if self.metadata_path.exists():
            try:
                with open(self.metadata_path, 'r') as f:
                    data = json.load(f)
                    for key, entry_dict in data.items():
                        self.lru[key] = CacheEntry(
                            path=Path(entry_dict["path"]),
                            last_access=entry_dict["last_access"],
                            size_bytes=entry_dict["size_bytes"],
                            voice=entry_dict["voice"]
                        )
            except Exception as e:
                print(f"Warning: Failed to load cache metadata: {e}")
                self.lru = {}

    def _save_metadata(self):
        """Save cache metadata to disk."""
        try:
            data = {
                key: {
                    "path": str(entry.path),
                    "last_access": entry.last_access,
                    "size_bytes": entry.size_bytes,
                    "voice": entry.voice
                }
                for key, entry in self.lru.items()
            }
            with open(self.metadata_path, 'w') as f:
                json.dump(data, f, indent=2)
        except Exception as e:
            print(f"Warning: Failed to save cache metadata: {e}")

    def _hash(self, text: str, voice: str) -> str:
        """Generate cache key from text and voice.

        Args:
            text: Text to synthesize
            voice: Voice name

        Returns:
            16-character hex hash
        """
        content = f"{text}:{voice}"
        return hashlib.sha256(content.encode()).hexdigest()[:16]

    def get(self, text: str, voice: str) -> Optional[bytes]:
        """Get cached audio if available.

        Args:
            text: Text that was synthesized
            voice: Voice used for synthesis

        Returns:
            Audio bytes if cached, None otherwise
        """
        cache_key = self._hash(text, voice)

        if cache_key in self.lru:
            entry = self.lru[cache_key]

            # Check if file still exists
            if not entry.path.exists():
                del self.lru[cache_key]
                self._save_metadata()
                return None

            # Update access time (LRU)
            entry.last_access = time.time()
            self._save_metadata()

            # Read and return audio
            try:
                return entry.path.read_bytes()
            except Exception as e:
                print(f"Warning: Failed to read cached audio: {e}")
                del self.lru[cache_key]
                self._save_metadata()
                return None

        return None

    def set(self, text: str, voice: str, audio_data: bytes):
        """Store audio in cache.

        Args:
            text: Text that was synthesized
            voice: Voice used for synthesis
            audio_data: Audio bytes to cache
        """
        cache_key = self._hash(text, voice)
        path = self.questions_dir / f"{cache_key}.opus"

        # Write audio to disk
        try:
            path.write_bytes(audio_data)
        except Exception as e:
            print(f"Warning: Failed to write audio to cache: {e}")
            return

        # Update LRU metadata
        self.lru[cache_key] = CacheEntry(
            path=path,
            last_access=time.time(),
            size_bytes=len(audio_data),
            voice=voice
        )

        # Evict old entries if needed
        self._evict_if_needed()

        # Save metadata
        self._save_metadata()

    def _evict_if_needed(self):
        """Evict least recently used entries if cache exceeds max size."""
        total_size = sum(entry.size_bytes for entry in self.lru.values())

        if total_size <= self.max_size_bytes:
            return

        # Sort by last access time (oldest first)
        sorted_entries = sorted(
            self.lru.items(),
            key=lambda x: x[1].last_access
        )

        # Remove oldest entries until under limit
        for key, entry in sorted_entries:
            if total_size <= self.max_size_bytes:
                break

            # Delete file
            try:
                if entry.path.exists():
                    entry.path.unlink()
            except Exception as e:
                print(f"Warning: Failed to delete cached file: {e}")

            # Remove from LRU
            del self.lru[key]
            total_size -= entry.size_bytes

    def get_static_feedback(self, result: str, variant: int = 0) -> Optional[bytes]:
        """Get pre-generated static feedback audio.

        Args:
            result: Evaluation result (correct, incorrect, etc.)
            variant: Phrase variant index (0, 1, 2, ...)

        Returns:
            Audio bytes if available, None otherwise
        """
        filename = f"feedback_{result}_{variant}.opus"
        path = self.static_dir / filename

        if path.exists():
            try:
                return path.read_bytes()
            except Exception as e:
                print(f"Warning: Failed to read static feedback: {e}")
                return None

        return None

    def set_static_feedback(self, result: str, variant: int, audio_data: bytes):
        """Store pre-generated static feedback audio.

        Args:
            result: Evaluation result (correct, incorrect, etc.)
            variant: Phrase variant index (0, 1, 2, ...)
            audio_data: Audio bytes to store
        """
        filename = f"feedback_{result}_{variant}.opus"
        path = self.static_dir / filename

        try:
            path.write_bytes(audio_data)
        except Exception as e:
            print(f"Warning: Failed to write static feedback: {e}")

    def get_cache_stats(self) -> Dict[str, any]:
        """Get cache statistics.

        Returns:
            Dictionary with cache stats
        """
        total_size = sum(entry.size_bytes for entry in self.lru.values())
        static_files = list(self.static_dir.glob("*.opus"))
        static_size = sum(f.stat().st_size for f in static_files if f.exists())

        return {
            "questions_cached": len(self.lru),
            "questions_size_mb": total_size / 1024 / 1024,
            "static_feedback_files": len(static_files),
            "static_size_mb": static_size / 1024 / 1024,
            "total_size_mb": (total_size + static_size) / 1024 / 1024,
            "max_size_mb": self.max_size_bytes / 1024 / 1024,
        }
