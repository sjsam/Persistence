"""Tests for the storage engine.

A deterministic fake embedder stands in for Ollama so the suite runs offline.
"""

from __future__ import annotations

import math

import pytest

from persistence.config import Config
from persistence.embeddings import EmbeddingError
from persistence.store import MemoryStore


class FakeEmbedder:
    """Maps text to a tiny deterministic vector based on keyword presence."""

    dim = 4
    model = "fake"

    # Each dimension fires on a topic keyword, so semantically similar texts
    # land near each other without needing a real model.
    _KEYWORDS = ("database", "embedding", "milk", "deploy")

    def __init__(self, fail: bool = False) -> None:
        self._fail = fail

    def embed(self, text: str) -> list[float]:
        if self._fail:
            raise EmbeddingError("simulated outage")
        t = text.lower()
        vec = [1.0 if kw in t else 0.0 for kw in self._KEYWORDS]
        # Normalize so cosine distance is well-defined; bias avoids a zero vector.
        vec = [v + 0.01 for v in vec]
        norm = math.sqrt(sum(v * v for v in vec))
        return [v / norm for v in vec]


def make_store(tmp_path, fail_embed: bool = False) -> MemoryStore:
    cfg = Config(
        db_path=tmp_path / "memory.db",
        ollama_url="http://unused",
        embed_model="fake",
        embed_dim=FakeEmbedder.dim,
        host="127.0.0.1",
        port=0,
        auth_token=None,
    )
    return MemoryStore(cfg, embedder=FakeEmbedder(fail=fail_embed))


def test_save_returns_memory(tmp_path):
    store = make_store(tmp_path)
    mem = store.save("proj", "we chose a database", tags=["db"])
    assert mem.id == 1
    assert mem.project == "proj"
    assert mem.tags == ["db"]
    assert mem.created_at.endswith("+00:00")


def test_save_is_append_only(tmp_path):
    store = make_store(tmp_path)
    store.save("proj", "database decision one")
    store.save("proj", "database decision two")
    mems = store.list_memories("proj")
    assert len(mems) == 2  # both deltas kept; nothing overwritten


def test_semantic_recall_ranks_relevant_first(tmp_path):
    store = make_store(tmp_path)
    store.save("proj", "we picked a database engine")
    store.save("proj", "embedding model is local")
    store.save("proj", "buy milk and eggs")
    results = store.recall("which database do we use", top_k=1)
    assert len(results) == 1
    assert "database" in results[0].summary


def test_recall_project_filter(tmp_path):
    store = make_store(tmp_path)
    store.save("a", "database in project a")
    store.save("b", "database in project b")
    results = store.recall("database", project="b", top_k=5)
    assert results
    assert all(m.project == "b" for m in results)


def test_recall_falls_back_to_keyword_when_embedding_fails(tmp_path):
    # Save WITH embeddings working, then recall with the embedder down.
    store = make_store(tmp_path)
    store.save("proj", "the deploy pipeline uses launchd")
    store.save("proj", "unrelated note about milk")

    store._embedder = FakeEmbedder(fail=True)  # simulate Ollama outage
    results = store.recall("deploy", top_k=5)
    assert results
    assert any("deploy" in m.summary for m in results)


def test_save_without_embeddings_then_keyword_recall(tmp_path):
    # Ollama down at save time: row stored without a vector, still findable by FTS.
    store = make_store(tmp_path, fail_embed=True)
    store.save("proj", "database chosen while ollama was offline")
    results = store.recall("database", top_k=5)
    assert results
    assert results[0].summary.startswith("database chosen")


def test_list_projects(tmp_path):
    store = make_store(tmp_path)
    store.save("alpha", "database note")
    store.save("alpha", "embedding note")
    store.save("beta", "milk note")
    projects = {p["project"]: p["count"] for p in store.list_projects()}
    assert projects == {"alpha": 2, "beta": 1}


def test_empty_inputs_rejected(tmp_path):
    store = make_store(tmp_path)
    with pytest.raises(ValueError):
        store.save("", "content")
    with pytest.raises(ValueError):
        store.save("proj", "   ")


def test_recall_empty_query_returns_empty(tmp_path):
    store = make_store(tmp_path)
    store.save("proj", "database note")
    assert store.recall("   ") == []


def test_persists_across_reopen(tmp_path):
    store = make_store(tmp_path)
    store.save("proj", "durable database note")
    store.close()
    store2 = make_store(tmp_path)  # reopen same file
    assert len(store2.list_memories("proj")) == 1


def test_backup_is_a_usable_copy(tmp_path):
    store = make_store(tmp_path)
    store.save("proj", "database note worth backing up")
    dest = store.backup(tmp_path / "bk" / "copy.db")
    assert dest.exists()

    # The backup opens independently and contains the same data.
    cfg = Config(
        db_path=dest,
        ollama_url="http://unused",
        embed_model="fake",
        embed_dim=FakeEmbedder.dim,
        host="127.0.0.1",
        port=0,
        auth_token=None,
    )
    restored = MemoryStore(cfg, embedder=FakeEmbedder())
    assert len(restored.list_memories("proj")) == 1
