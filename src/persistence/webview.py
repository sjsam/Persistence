"""A small read-only web view for browsing saved memory.

Mounted alongside the MCP endpoint on the same server. Read-only by design —
all writes go through the explicit `save_memory` MCP tool (CLAUDE.md: saving is
explicit only). Useful for eyeballing what's stored without an MCP client.
"""

from __future__ import annotations

import html

from starlette.requests import Request
from starlette.responses import HTMLResponse, JSONResponse
from starlette.routing import Route

from .store import MemoryStore

_STYLE = """
  :root { color-scheme: light dark; }
  body { font: 15px/1.5 -apple-system, system-ui, sans-serif; max-width: 820px;
         margin: 2rem auto; padding: 0 1rem; }
  h1 { font-size: 1.4rem; } h1 a { text-decoration: none; color: inherit; }
  .proj { display: flex; justify-content: space-between; padding: .6rem .8rem;
          border: 1px solid color-mix(in srgb, currentColor 18%, transparent);
          border-radius: 8px; margin: .4rem 0; text-decoration: none; color: inherit; }
  .proj:hover { background: color-mix(in srgb, currentColor 8%, transparent); }
  .count { opacity: .6; font-variant-numeric: tabular-nums; }
  .mem { border: 1px solid color-mix(in srgb, currentColor 18%, transparent);
         border-radius: 8px; padding: .7rem .9rem; margin: .6rem 0; }
  .meta { font-size: .8rem; opacity: .6; margin-bottom: .3rem; }
  .tag { display: inline-block; font-size: .75rem; padding: 0 .4rem;
         border-radius: 4px; background: color-mix(in srgb, currentColor 14%, transparent);
         margin-right: .3rem; }
  .empty { opacity: .6; font-style: italic; }
"""


def _page(title: str, body: str) -> HTMLResponse:
    return HTMLResponse(
        f"<!doctype html><meta charset=utf-8><title>{html.escape(title)}</title>"
        f"<meta name=viewport content='width=device-width,initial-scale=1'>"
        f"<style>{_STYLE}</style>"
        f"<h1><a href='/'>🧠 Persistence</a></h1>{body}"
    )


def make_routes(store: MemoryStore) -> list[Route]:
    def index(request: Request):
        projects = store.list_projects()
        if not projects:
            rows = "<p class=empty>No memories saved yet.</p>"
        else:
            rows = "".join(
                f"<a class=proj href='/p/{html.escape(p['project'])}'>"
                f"<span>{html.escape(p['project'])}</span>"
                f"<span class=count>{p['count']} · {html.escape(p['last_saved'])}</span></a>"
                for p in projects
            )
        return _page("Persistence", rows)

    def project(request: Request):
        name = request.path_params["name"]
        mems = store.list_memories(name)
        if not mems:
            body = f"<h2>{html.escape(name)}</h2><p class=empty>No memories.</p>"
        else:
            cards = []
            for m in mems:
                tags = "".join(f"<span class=tag>{html.escape(t)}</span>" for t in m.tags)
                cards.append(
                    f"<div class=mem><div class=meta>#{m.id} · "
                    f"{html.escape(m.source_tool)} · {html.escape(m.created_at)}</div>"
                    f"<div>{html.escape(m.summary)}</div>"
                    f"<div style='margin-top:.4rem'>{tags}</div></div>"
                )
            body = f"<h2>{html.escape(name)} <span class=count>({len(mems)})</span></h2>" + "".join(cards)
        return _page(f"{name} — Persistence", body)

    def healthz(request: Request):
        return JSONResponse({"ok": True, "projects": len(store.list_projects())})

    return [
        Route("/", index),
        Route("/p/{name}", project),
        Route("/healthz", healthz),
    ]
