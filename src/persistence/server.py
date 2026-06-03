"""MCP server: exposes the memory store over Streamable HTTP via FastMCP.

Tools (CLAUDE.md):
  * save_memory(project, content, tags?)   — append a distilled summary
  * recall_memory(query, project?, top_k?)  — semantic search
  * list_projects()                         — known projects
  * list_memories(project)                  — a project's deltas

Optional shared-token auth: set PERSISTENCE_TOKEN and clients must send
`Authorization: Bearer <token>`.
"""

from __future__ import annotations

import uvicorn
from fastmcp import FastMCP
from starlette.middleware import Middleware
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse

from .config import Config
from .store import MemoryStore
from .webview import make_routes

config = Config.from_env()
store = MemoryStore(config)

mcp = FastMCP(
    name="persistence",
    instructions=(
        "Shared cross-tool memory. Save distilled summaries of a conversation "
        "with save_memory, and retrieve relevant context in another tool with "
        "recall_memory. Saving is explicit only — never auto-save."
    ),
)


@mcp.tool
def save_memory(
    project: str, content: str, tags: list[str] | None = None
) -> dict:
    """Append a distilled summary of the current conversation as a new memory.

    Pass a concise, self-contained summary of the decisions, state, and facts
    worth carrying to another tool — not the raw transcript. Saving is explicit.

    Args:
        project: project name this memory belongs to (e.g. "persistence").
        content: the distilled summary text to store.
        tags: optional list of free-form tags.
    """
    mem = store.save(
        project=project,
        content=content,
        tags=tags,
        source_tool="mcp",
    )
    return {"saved": True, "memory": mem.to_dict()}


@mcp.tool
def recall_memory(query: str, project: str | None = None, top_k: int = 5) -> dict:
    """Semantically recall the most relevant saved memories for a query.

    Args:
        query: what you want to remember about.
        project: optional project filter.
        top_k: max number of memories to return (default 5).
    """
    results = store.recall(query=query, project=project, top_k=top_k)
    return {"count": len(results), "memories": [m.to_dict() for m in results]}


@mcp.tool
def list_projects() -> dict:
    """List all known projects with their memory counts and last-saved time."""
    return {"projects": store.list_projects()}


@mcp.tool
def list_memories(project: str) -> dict:
    """List all saved memory deltas for a project, newest first."""
    mems = store.list_memories(project)
    return {"project": project, "count": len(mems), "memories": [m.to_dict() for m in mems]}


class _TokenAuthMiddleware(BaseHTTPMiddleware):
    """Reject requests lacking the shared bearer token, when one is configured."""

    def __init__(self, app, token: str) -> None:
        super().__init__(app)
        self._expected = f"Bearer {token}"

    async def dispatch(self, request: Request, call_next):
        if request.headers.get("authorization") != self._expected:
            return JSONResponse({"error": "unauthorized"}, status_code=401)
        return await call_next(request)


def build_app(cfg: Config = config):
    """Build the Streamable HTTP ASGI app, with token auth if configured.

    Mounts the MCP endpoint at /mcp and the read-only web browse view at /.
    """
    middleware = []
    if cfg.auth_token:
        middleware.append(Middleware(_TokenAuthMiddleware, token=cfg.auth_token))
    app = mcp.http_app(path="/mcp", middleware=middleware, transport="http")
    # Add the browse routes onto the same app (keeps FastMCP's lifespan intact).
    app.router.routes.extend(make_routes(store))
    return app


def run() -> None:
    """Entry point: start the Streamable HTTP MCP server."""
    auth_note = "token auth ON" if config.auth_token else "token auth OFF (LAN only)"
    print(
        f"Persistence MCP server → http://{config.host}:{config.port}/mcp\n"
        f"  web:    http://{config.host}:{config.port}/  (read-only browse view)\n"
        f"  db:     {config.db_path}\n"
        f"  embed:  {config.embed_model} ({config.embed_dim}d) @ {config.ollama_url}\n"
        f"  auth:   {auth_note}",
        flush=True,
    )
    uvicorn.run(build_app(), host=config.host, port=config.port, log_level="info")


if __name__ == "__main__":
    run()
