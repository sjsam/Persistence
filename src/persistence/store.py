"""SQLite + sqlite-vec storage engine.

Design invariants (CLAUDE.md):
  * One row per saved memory: project, summary, tags, source_tool, created_at, embedding.
  * Writes are append-only deltas — never rewrite a project's whole memory.
  * Recall is semantic (vector search) with a keyword fallback if Ollama is down.
"""

from __future__ import annotations

import json
import sqlite3
import struct
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import sqlite_vec

from .config import Config
from .embeddings import Embedder, EmbeddingError


@dataclass
class Memory:
    id: int
    project: str
    summary: str
    tags: list[str]
    source_tool: str
    created_at: str
    score: float | None = None  # cosine distance when returned from recall

    def to_dict(self) -> dict:
        d = {
            "id": self.id,
            "project": self.project,
            "summary": self.summary,
            "tags": self.tags,
            "source_tool": self.source_tool,
            "created_at": self.created_at,
        }
        if self.score is not None:
            d["score"] = round(self.score, 4)
        return d


def _serialize_f32(vector: list[float]) -> bytes:
    """Pack a float list into the little-endian f32 blob sqlite-vec expects."""
    return struct.pack(f"{len(vector)}f", *vector)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class MemoryStore:
    """Owns the SQLite connection and all read/write logic."""

    def __init__(self, config: Config, embedder: Embedder | None = None) -> None:
        self._config = config
        self._embedder = embedder or Embedder(config)
        self._conn = self._connect(config.db_path)
        self._init_schema()

    @staticmethod
    def _connect(db_path: Path) -> sqlite3.Connection:
        db_path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(db_path), check_same_thread=False)
        conn.row_factory = sqlite3.Row
        conn.enable_load_extension(True)
        sqlite_vec.load(conn)
        conn.enable_load_extension(False)
        conn.execute("PRAGMA journal_mode=WAL;")
        return conn

    def _init_schema(self) -> None:
        dim = self._embedder.dim
        with self._conn:
            self._conn.execute(
                """
                CREATE TABLE IF NOT EXISTS memories (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    project     TEXT NOT NULL,
                    summary     TEXT NOT NULL,
                    tags        TEXT NOT NULL DEFAULT '[]',
                    source_tool TEXT NOT NULL DEFAULT 'unknown',
                    created_at  TEXT NOT NULL,
                    embed_model TEXT
                );
                """
            )
            self._conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_memories_project ON memories(project);"
            )
            # Virtual table holding the vectors, keyed by the memories.id rowid.
            self._conn.execute(
                f"""
                CREATE VIRTUAL TABLE IF NOT EXISTS memory_vectors USING vec0(
                    embedding float[{dim}]
                );
                """
            )
            # Full-text fallback index over summaries (keyword search when
            # Ollama is unavailable).
            self._conn.execute(
                """
                CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
                    summary, content='memories', content_rowid='id'
                );
                """
            )

    # ------------------------------------------------------------------ writes

    def save(
        self,
        project: str,
        content: str,
        tags: list[str] | None = None,
        source_tool: str = "unknown",
    ) -> Memory:
        """Append a new memory delta. Embeds the summary if Ollama is available."""
        project = project.strip()
        content = content.strip()
        if not project:
            raise ValueError("project must not be empty")
        if not content:
            raise ValueError("content must not be empty")

        tags = tags or []
        created_at = _now()
        tags_json = json.dumps(tags)

        # Embed first (outside the txn) so a failure doesn't leave a half-write.
        vector: list[float] | None = None
        try:
            vector = self._embedder.embed(content)
            embed_model = self._embedder.model
        except EmbeddingError:
            embed_model = None  # stored without a vector; recall falls back to FTS

        with self._conn:
            cur = self._conn.execute(
                """
                INSERT INTO memories (project, summary, tags, source_tool, created_at, embed_model)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (project, content, tags_json, source_tool, created_at, embed_model),
            )
            row_id = cur.lastrowid
            self._conn.execute(
                "INSERT INTO memory_fts (rowid, summary) VALUES (?, ?)",
                (row_id, content),
            )
            if vector is not None:
                self._conn.execute(
                    "INSERT INTO memory_vectors (rowid, embedding) VALUES (?, ?)",
                    (row_id, _serialize_f32(vector)),
                )

        return Memory(
            id=row_id,
            project=project,
            summary=content,
            tags=tags,
            source_tool=source_tool,
            created_at=created_at,
        )

    # ------------------------------------------------------------------- reads

    def recall(
        self, query: str, project: str | None = None, top_k: int = 5
    ) -> list[Memory]:
        """Semantic search; transparently falls back to keyword search."""
        query = query.strip()
        if not query:
            return []
        try:
            vector = self._embedder.embed(query)
            return self._recall_vector(vector, project, top_k)
        except EmbeddingError:
            return self._recall_keyword(query, project, top_k)

    def _recall_vector(
        self, vector: list[float], project: str | None, top_k: int
    ) -> list[Memory]:
        # sqlite-vec KNN, then join back to memories. We over-fetch when a
        # project filter is set, since the filter is applied after the scan.
        scan_k = top_k if project is None else max(top_k * 8, 40)
        rows = self._conn.execute(
            """
            SELECT m.*, v.distance AS distance
            FROM memory_vectors v
            JOIN memories m ON m.id = v.rowid
            WHERE v.embedding MATCH ? AND k = ?
            ORDER BY v.distance
            """,
            (_serialize_f32(vector), scan_k),
        ).fetchall()

        results: list[Memory] = []
        for row in rows:
            if project is not None and row["project"] != project:
                continue
            results.append(self._row_to_memory(row, score=row["distance"]))
            if len(results) >= top_k:
                break
        return results

    def _recall_keyword(
        self, query: str, project: str | None, top_k: int
    ) -> list[Memory]:
        # Escape FTS5 special chars by quoting each token as a phrase.
        match = " OR ".join(f'"{tok}"' for tok in query.split() if tok)
        if not match:
            return []
        sql = """
            SELECT m.*, bm25(memory_fts) AS distance
            FROM memory_fts
            JOIN memories m ON m.id = memory_fts.rowid
            WHERE memory_fts MATCH ?
        """
        params: list = [match]
        if project is not None:
            sql += " AND m.project = ?"
            params.append(project)
        sql += " ORDER BY distance LIMIT ?"
        params.append(top_k)
        rows = self._conn.execute(sql, params).fetchall()
        return [self._row_to_memory(r, score=r["distance"]) for r in rows]

    def list_projects(self) -> list[dict]:
        rows = self._conn.execute(
            """
            SELECT project, COUNT(*) AS count, MAX(created_at) AS last_saved
            FROM memories GROUP BY project ORDER BY last_saved DESC
            """
        ).fetchall()
        return [dict(r) for r in rows]

    def list_memories(self, project: str) -> list[Memory]:
        rows = self._conn.execute(
            "SELECT * FROM memories WHERE project = ? ORDER BY created_at DESC, id DESC",
            (project.strip(),),
        ).fetchall()
        return [self._row_to_memory(r) for r in rows]

    # ------------------------------------------------------------------ helpers

    @staticmethod
    def _row_to_memory(row: sqlite3.Row, score: float | None = None) -> Memory:
        return Memory(
            id=row["id"],
            project=row["project"],
            summary=row["summary"],
            tags=json.loads(row["tags"]),
            source_tool=row["source_tool"],
            created_at=row["created_at"],
            score=score,
        )

    def backup(self, dest: Path) -> Path:
        """Hot-copy the database to `dest` using SQLite's online backup API.

        Safe to run while the server is live — no need to stop writes.
        """
        dest = Path(dest).expanduser()
        dest.parent.mkdir(parents=True, exist_ok=True)
        target = sqlite3.connect(str(dest))
        try:
            with target:
                self._conn.backup(target)
        finally:
            target.close()
        return dest

    def close(self) -> None:
        self._conn.close()
