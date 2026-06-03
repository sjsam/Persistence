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

## Run the server (quick / foreground)

```bash
persistence-server
# → Persistence MCP server → http://0.0.0.0:8077/mcp
#   web: http://0.0.0.0:8077/  (read-only browse view)
```

## Deploy as an always-on server

One installer per platform: each creates a standalone venv at `~/.persistence/venv`
(`%USERPROFILE%\.persistence` on Windows), generates an auth **token**, binds to the
LAN (`0.0.0.0:8077`), and registers an auto-start service. Re-runnable; reuses an
existing `token.txt`/`memory.db`.

| Platform | Command (from the cloned repo) | Auto-start | Details |
|----------|--------------------------------|------------|---------|
| **macOS** | `bash deploy/macos/install.sh` | launchd | install **outside** `~/Documents` (TCC) |
| **Linux** | `bash deploy/linux/install.sh` | systemd user unit + linger | — |
| **WSL2** | `bash deploy/linux/install.sh`, then follow [`deploy/wsl/README.md`](deploy/wsl/README.md) | systemd in WSL + Windows task | NAT networking needs mirrored mode or a port-proxy |
| **Windows** (native) | `powershell -ExecutionPolicy Bypass -File deploy\windows\install.ps1` | Scheduled Task | opens firewall TCP 8077 |

Each installer prints the **token** and the **LAN URL** (`http://<host-ip>:8077/mcp`)
to use when wiring clients. To migrate between hosts, copy `~/.persistence/memory.db`
(and `token.txt` to keep the same token) before first run — the embedding model is
the same everywhere, so stored vectors stay valid.

> **LAN reach:** give the host a **static IP / DHCP reservation** so the URL never
> changes. Always run with `PERSISTENCE_TOKEN` set once you leave `localhost`.

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

### Convenience scripts (recommended)

Point every installed client at a server in one command:

```bash
# macOS / Linux / WSL-hosted clients
scripts/connect-client.sh --url http://<host-ip>:8077/mcp --token <TOKEN>
```
```powershell
# Windows-hosted clients (Claude Desktop, Antigravity, …)
scripts\connect-client.ps1 -Url http://<host-ip>:8077/mcp -Token <TOKEN>
```

Both auto-detect which clients are present (Claude Code, Claude Desktop,
Antigravity, ollmcp), merge into existing configs without clobbering them, and are
re-runnable. Limit with `--client claude-code,ollmcp` (`-Clients` on PowerShell). If
`--token` is omitted it's read from `~/.persistence/token.txt`. Restart Claude
Desktop / Antigravity afterward to load the change.

### Manual wiring (reference)

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

## Auto-start on boot

Use the platform installer under [`deploy/`](deploy/) (see **Deploy as an
always-on server** above) — they register launchd / systemd / Scheduled Task
units for you. Data on disk always survives a reboot; only the process needs to
come back up.

## Tests

```bash
.venv/bin/python -m pytest
```
