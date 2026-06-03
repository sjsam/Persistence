# CLAUDE.md — Persistence

Guidance for AI agents (Claude, Gemini/Antigravity, local models) working in this repo.

## What this project is

**Persistence** is a local, provider-agnostic **memory server** for AI chats. It lets you save the context of a conversation in one tool (e.g. Claude Desktop) and recall it in another (e.g. Google Antigravity, Ollama) without losing state — solving the productivity loss from switching providers when you hit rate limits.

The unifying idea: all target tools speak **MCP** (Model Context Protocol). So we build **one** local MCP "memory server" that every tool connects to as a shared brain. Save and recall are ordinary chat commands ("save this to memory" / "recall project X") — no per-tool glue.

## Confirmed design decisions

These are locked. Do not silently change them.

- **Save unit:** distilled summary (LLM-written summary of decisions/state/facts), not raw transcript.
- **Recall:** semantic retrieval (RAG) — return only the relevant chunks for a query.
- **Embeddings:** fully local via Ollama (`nomic-embed-text`). Offline, private, free.
- **Host:** the user's main workstation, reachable over the LAN.
- **Saving is explicit only.** Nothing is auto-captured; the user must request a save.
- **Writes are append-only deltas.** Each save inserts a new row; never rewrite a project's whole memory. Recall aggregates relevant deltas.

## Architecture

```
  Claude Desktop ─┐
  Antigravity     ├─ MCP over HTTP ─▶  Memory Server (workstation:8077)
  Ollama (ollmcp) ┘                         │
                                            ├─ SQLite + sqlite-vec   (storage + vector index)
                                            └─ Ollama embeddings     (nomic-embed-text, local)
```

- **Storage:** single SQLite file with the `sqlite-vec` extension. One row per saved memory: `project, summary, tags, source_tool, created_at, embedding`. Single file = trivial backup, fast, no DB server to babysit. Summaries are plain text so memory is never a black box.
- **Persistence across restarts:** data is on disk and survives reboots/crashes. The **server process** must auto-start on boot (launch agent / service) so memory is reachable again; the data itself is always safe.
- **Embeddings:** local Ollama model `nomic-embed-text` (~274 MB, 768-dim, 8k ctx). Used for BOTH writes and reads. **Critical rule:** the same embedding model must be used for save and recall — vectors from different models are not comparable. Switching models requires re-embedding all stored memories once.
- **Who writes the summary:** the *calling* chat model distills the conversation into the summary as part of the `save_memory` call (it already has context, no extra cost). Fallback: server-side summarization via local Ollama if a raw dump is sent.
- **Transport:** MCP Streamable HTTP bound to the LAN, e.g. `http://<workstation>.local:8077/mcp`. Add an optional shared-token header and firewall to LAN only.
- **Expected recall latency:** ~50–200 ms end to end (query embedding dominates; sqlite-vec scan is low-ms up to ~100k memories). Add an ANN index only if the corpus ever reaches millions of vectors.

## MCP tools exposed

- `save_memory(project, content, tags?)` — append a distilled summary as a new delta.
- `recall_memory(query, project?, top_k?)` — semantic search, returns relevant chunks.
- `list_projects()` — list known projects.
- `list_memories(project)` — list a project's saved deltas.

## Tech stack

Python 3.11+, FastMCP (Python MCP SDK), `sqlite-vec`, Ollama (`nomic-embed-text`), `httpx`.

## Build phases

1. **Prereqs** — Python 3.11+, Ollama running with `nomic-embed-text` pulled, choose a port (default 8077).
2. **Core engine** — SQLite + sqlite-vec schema, save/recall/embed logic; test via CLI.
3. **MCP wrapper** — expose tools over HTTP (FastMCP); verify with Claude Desktop.
4. **Wire other clients** — Antigravity (`~/.gemini/config/mcp_config.json`) and Ollama (`ollmcp`); prove a real cross-tool handoff.
5. **Polish** — tags, project auto-detect, small web view to browse memory, backup + auto-start service.

## Client wiring (reference)

- **Claude Desktop:** add the server to `claude_desktop_config.json` under `mcpServers` (HTTP URL, or via `mcp-remote` bridge).
- **Antigravity:** add an entry to `~/.gemini/config/mcp_config.json` pointing at the server URL (or install from its MCP store).
- **Ollama:** connect through `ollmcp` (MCP Client for Ollama) pointing at the server URL.

## Conventions for agents

- Keep the local-LLM dependency narrow: only embeddings require Ollama. Raw read/write needs no model; keyword/full-text search is the fallback if Ollama is unavailable.
- Never make `save` implicit. Respect explicit-save-only.
- Preserve append-only semantics; add a separate optional `consolidate` step rather than mutating existing deltas.
- Default project tagging: explicit, with a server-suggested project name.
- Default auth: shared-token header over LAN.

## Open points (decide before/while building)

1. **Project tagging** — explicit vs auto-suggested (default: explicit-with-suggestion).
2. **Auth** — bare LAN vs shared-token header (default: token, ~5 lines).

## Status

Design approved. **Phases 1–3 implemented** (core engine, CLI, MCP HTTP server) and
verified end-to-end against a live Ollama + real MCP client. See `README.md`.

- `src/persistence/` — `config`, `embeddings` (Ollama), `store` (SQLite + sqlite-vec,
  append-only, semantic recall with keyword fallback), `server` (FastMCP HTTP), `cli`.
- `tests/` — 10 passing tests (offline, via an injected fake embedder).
- `deploy/com.persistence.server.plist` — launchd auto-start (phase 5).
- `webview.py` — read-only browse view; backup via SQLite online-backup API.
- Verified live: combined server serves the web view (`/`, `/healthz`, `/p/{project}`)
  AND the MCP endpoint (`/mcp`) on one port.
- Remaining: wire real clients end-to-end against the actual desktop apps (phase 4);
  project auto-detect (phase 5).
