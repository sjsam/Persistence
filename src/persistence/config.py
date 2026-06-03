"""Configuration, sourced from environment variables with sane defaults.

All settings are optional; the defaults match the design in CLAUDE.md.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _default_db_path() -> Path:
    """Store the SQLite file under the user's data dir, overridable by env."""
    base = os.environ.get("PERSISTENCE_DATA_DIR")
    if base:
        return Path(base).expanduser() / "memory.db"
    return Path.home() / ".persistence" / "memory.db"


@dataclass(frozen=True)
class Config:
    # Storage
    db_path: Path

    # Embeddings (Ollama, local)
    ollama_url: str
    embed_model: str
    # nomic-embed-text is 768-dim. Kept explicit so a model swap is a loud,
    # deliberate change (see CLAUDE.md: same model for save AND recall).
    embed_dim: int

    # Transport
    host: str
    port: int
    auth_token: str | None  # optional shared-token header for LAN auth

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            db_path=Path(
                os.environ.get("PERSISTENCE_DB_PATH", str(_default_db_path()))
            ).expanduser(),
            ollama_url=os.environ.get("OLLAMA_URL", "http://localhost:11434"),
            embed_model=os.environ.get("PERSISTENCE_EMBED_MODEL", "nomic-embed-text"),
            embed_dim=int(os.environ.get("PERSISTENCE_EMBED_DIM", "768")),
            host=os.environ.get("PERSISTENCE_HOST", "0.0.0.0"),
            port=int(os.environ.get("PERSISTENCE_PORT", "8077")),
            auth_token=os.environ.get("PERSISTENCE_TOKEN") or None,
        )
