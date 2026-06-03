"""Local embeddings via Ollama (nomic-embed-text).

CRITICAL (CLAUDE.md): the SAME model must embed both saves and recalls —
vectors from different models are not comparable. The dimension is asserted
on every embed so a silent model/dim mismatch fails loudly.
"""

from __future__ import annotations

import httpx

from .config import Config


class EmbeddingError(RuntimeError):
    """Raised when Ollama is unreachable or returns an unusable response."""


class Embedder:
    """Thin wrapper over Ollama's /api/embeddings endpoint."""

    def __init__(self, config: Config) -> None:
        self._url = config.ollama_url.rstrip("/")
        self._model = config.embed_model
        self._dim = config.embed_dim

    @property
    def model(self) -> str:
        return self._model

    @property
    def dim(self) -> int:
        return self._dim

    def available(self) -> bool:
        """True if Ollama answers and the configured model can embed."""
        try:
            self.embed("ping")
            return True
        except EmbeddingError:
            return False

    def embed(self, text: str) -> list[float]:
        """Return the embedding vector for a single string."""
        payload = {"model": self._model, "prompt": text}
        try:
            resp = httpx.post(
                f"{self._url}/api/embeddings", json=payload, timeout=30.0
            )
            resp.raise_for_status()
        except httpx.HTTPError as exc:  # network error, 404 model, etc.
            raise EmbeddingError(
                f"Ollama embedding request failed ({self._url}, model={self._model}): {exc}"
            ) from exc

        data = resp.json()
        vector = data.get("embedding")
        if not isinstance(vector, list) or not vector:
            raise EmbeddingError(f"Ollama returned no embedding: {data!r}")
        if len(vector) != self._dim:
            raise EmbeddingError(
                f"Embedding dim mismatch: got {len(vector)}, expected {self._dim}. "
                f"Did the embed model change? Re-embed all memories if so."
            )
        return [float(x) for x in vector]
