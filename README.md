# Persistence

A local, provider-agnostic **memory server** for AI chats. Save the context of a
conversation in one tool (Claude Desktop) and recall it in another (Google
Antigravity, Ollama) without losing state — no more starting over when you switch
providers or hit a rate limit.

Every tool speaks **MCP** (Model Context Protocol), so Persistence is one local
MCP server that each tool connects to as a shared brain. Save and recall are
ordinary chat commands ("save this to memory" / "recall project X").

## How it works

```
  Claude Desktop ─┐
  Antigravity     ├─ MCP over HTTP ─▶  Persistence (workstation:8077)
  Ollama (ollmcp) ┘                         │
                                            ├─ SQLite + sqlite-vec   (storage + vector index)
                                            └─ Ollama embeddings     (nomic-embed-text, local)
```

- **Storage:** one SQLite file with the `sqlite-vec` extension. One row per saved
  memory (`project, summary, tags, source_tool, created_at, embedding`). Summaries
  are plain text — memory is never a black box.
- **Embeddings:** fully local via Ollama `nomic-embed-text` (768-dim). Offline,
  private, free. The *same* model embeds both saves and recalls.
- **Recall:** semantic (vector) search returns only the relevant chunks. If Ollama
  is unavailable, recall transparently falls back to keyword (FTS5) search.
- **Writes are append-only deltas.** Each save inserts a new row; a project's
  memory is never rewritten. Saving is **explicit only** — nothing is auto-captured.

## MCP tools

| Tool | Purpose |
|------|---------|
| `save_memory(project, content, tags?)` | append a distilled summary as a new delta |
| `recall_memory(query, project?, top_k?)` | semantic search, returns relevant chunks |
| `list_projects()` | list known projects |
| `list_memories(project)` | list a project's saved deltas |

## Requirements

- Python 3.11+
- [Ollama](https://ollama.com) running with the embedding model pulled:
  ```bash
  ollama pull nomic-embed-text
  ```

## Install

```bash
python3 -m venv .venv
.venv/bin/pip install -e .
```

## Quick start (CLI)

The CLI exercises the engine without any MCP client — useful for testing.

```bash
persistence doctor                                   # check Ollama + DB health
persistence save persistence "Chose SQLite + sqlite-vec; port 8077" --tags design,db
persistence recall "what database are we using?"     # semantic search
persistence projects
persistence list persistence
```

## Run the server

```bash
persistence-server
# → Persistence MCP server → http://0.0.0.0:8077/mcp
```

### Configuration (environment variables)

| Variable | Default | Meaning |
|----------|---------|---------|
| `PERSISTENCE_DB_PATH` | `~/.persistence/memory.db` | SQLite file location |
| `PERSISTENCE_DATA_DIR` | — | dir for `memory.db` (if `DB_PATH` unset) |
| `OLLAMA_URL` | `http://localhost:11434` | Ollama endpoint |
| `PERSISTENCE_EMBED_MODEL` | `nomic-embed-text` | embedding model |
| `PERSISTENCE_EMBED_DIM` | `768` | embedding dimension |
| `PERSISTENCE_HOST` | `0.0.0.0` | bind host |
| `PERSISTENCE_PORT` | `8077` | bind port |
| `PERSISTENCE_TOKEN` | — | if set, require `Authorization: Bearer <token>` |

> **Switching embedding models requires re-embedding all stored memories** —
> vectors from different models are not comparable. The dimension is asserted on
> every embed so a mismatch fails loudly rather than corrupting recall.

## Client wiring

Examples below include the `Authorization: Bearer <TOKEN>` header — required
whenever `PERSISTENCE_TOKEN` is set on the server. Omit it if you run tokenless.

**Claude Code** — one command (the `--header` flag is variadic, so it must come **last**):

```bash
claude mcp add --transport http --scope user persistence \
  http://localhost:8077/mcp --header "Authorization: Bearer <TOKEN>"
claude mcp list   # verify: persistence ... ✓ Connected
```

**Claude Desktop** — `claude_desktop_config.json`, via the `mcp-remote` bridge.
The header is passed as two extra args:

```json
{
  "mcpServers": {
    "persistence": {
      "command": "npx",
      "args": [
        "-y", "mcp-remote", "http://localhost:8077/mcp",
        "--header", "Authorization: Bearer <TOKEN>"
      ]
    }
  }
}
```

**Antigravity** — `~/.gemini/config/mcp_config.json`. Uses `serverUrl` (NOT
`httpUrl` — that yields "serverURL or command must be specified"), header as a
`headers` map:

```json
{
  "mcpServers": {
    "persistence": {
      "serverUrl": "http://localhost:8077/mcp",
      "headers": { "Authorization": "Bearer <TOKEN>" }
    }
  }
}
```

**Ollama** — via [`ollmcp`](https://github.com/jonigl/mcp-client-for-ollama).
Put the server in a `--servers-json` file (header as a `headers` map), then launch
with a **chat** model (not the embedding model):

```json
{
  "mcpServers": {
    "persistence": {
      "type": "streamable_http",
      "url": "http://localhost:8077/mcp",
      "headers": { "Authorization": "Bearer <TOKEN>" }
    }
  }
}
```
```bash
ollmcp --servers-json ~/.persistence/ollmcp-servers.json --model qwen2.5:7b
```

> From another device on the LAN, replace `localhost` with the host's name
> (e.g. `http://workstation.local:8077/mcp`).

## Auto-start on boot (macOS launchd)

See `deploy/com.persistence.server.plist` — copy it to
`~/Library/LaunchAgents/` and `launchctl load` it so memory is reachable after a
reboot. (Data on disk always survives; only the process needs restarting.)

## Tests

```bash
.venv/bin/python -m pytest
```
