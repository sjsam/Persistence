"""Tests for the read-only web browse view."""

from __future__ import annotations

from starlette.applications import Starlette
from starlette.testclient import TestClient

from persistence.webview import make_routes
from test_store import FakeEmbedder, make_store


def _client(tmp_path):
    store = make_store(tmp_path)
    store.save("alpha", "we chose a database engine", tags=["db", "design"])
    app = Starlette(routes=make_routes(store))
    return TestClient(app)


def test_index_lists_projects(tmp_path):
    client = _client(tmp_path)
    resp = client.get("/")
    assert resp.status_code == 200
    assert "alpha" in resp.text


def test_project_page_shows_memory_and_tags(tmp_path):
    client = _client(tmp_path)
    resp = client.get("/p/alpha")
    assert resp.status_code == 200
    assert "database engine" in resp.text
    assert "design" in resp.text  # tag rendered


def test_html_is_escaped(tmp_path):
    store = make_store(tmp_path)
    store.save("xss", "<script>alert(1)</script> database note")
    app = Starlette(routes=make_routes(store))
    client = TestClient(app)
    resp = client.get("/p/xss")
    assert "<script>alert(1)</script>" not in resp.text
    assert "&lt;script&gt;" in resp.text


def test_healthz(tmp_path):
    client = _client(tmp_path)
    resp = client.get("/healthz")
    assert resp.status_code == 200
    assert resp.json()["ok"] is True
