#!/usr/bin/env bash
#
# Wire local MCP clients to a Persistence server (macOS / Linux / WSL).
#
#   scripts/connect-client.sh --url http://192.168.1.50:8077/mcp --token <TOKEN>
#   scripts/connect-client.sh --url http://localhost:8077/mcp           # token read from ~/.persistence/token.txt
#   scripts/connect-client.sh --url ... --client claude-code,ollmcp     # subset
#
# Clients: claude-code, claude-desktop, antigravity, ollmcp  (default: all).
# Only configures clients that are actually present. Re-runnable (idempotent).
set -euo pipefail

URL=""; TOKEN=""; CLIENTS="all"
while [ $# -gt 0 ]; do
    case "$1" in
        --url) URL="$2"; shift 2;;
        --token) TOKEN="$2"; shift 2;;
        --client|--clients) CLIENTS="$2"; shift 2;;
        *) echo "unknown arg: $1" >&2; exit 2;;
    esac
done

[ -n "$URL" ] || { echo "ERROR: --url is required" >&2; exit 2; }
if [ -z "$TOKEN" ] && [ -f "$HOME/.persistence/token.txt" ]; then
    TOKEN="$(cat "$HOME/.persistence/token.txt")"
fi
AUTH="Bearer $TOKEN"

want() { [ "$CLIENTS" = "all" ] || [[ ",$CLIENTS," == *",$1,"* ]]; }

# --- Claude Code ------------------------------------------------------------
if want claude-code && command -v claude >/dev/null 2>&1; then
    claude mcp remove persistence -s user >/dev/null 2>&1 || true
    if [ -n "$TOKEN" ]; then
        # --header is variadic, so it MUST come last
        claude mcp add --transport http --scope user persistence "$URL" \
            --header "Authorization: $AUTH" >/dev/null
    else
        claude mcp add --transport http --scope user persistence "$URL" >/dev/null
    fi
    echo "✓ Claude Code configured"
elif want claude-code; then
    echo "· Claude Code skipped (claude CLI not found)"
fi

# --- Claude Desktop + Antigravity + ollmcp (JSON via python) ----------------
URL="$URL" AUTH="$AUTH" TOKEN="$TOKEN" CLIENTS="$CLIENTS" python3 - <<'PY'
import json, os, sys, pathlib, platform

url, auth, token, clients = (os.environ[k] for k in ("URL","AUTH","TOKEN","CLIENTS"))
def want(name): return clients == "all" or name in clients.split(",")
home = pathlib.Path.home()

def merge(path: pathlib.Path, mutate):
    path.parent.mkdir(parents=True, exist_ok=True)
    data = {}
    if path.exists() and path.stat().st_size > 0:
        data = json.loads(path.read_text())
    mutate(data)
    path.write_text(json.dumps(data, indent=2) + "\n")

# Claude Desktop
if want("claude-desktop"):
    if platform.system() == "Darwin":
        cd = home / "Library/Application Support/Claude/claude_desktop_config.json"
    else:
        cd = home / ".config/Claude/claude_desktop_config.json"
    if cd.exists():
        npx = "npx"
        args = ["-y", "mcp-remote", url]
        if token:
            args += ["--header", f"Authorization: {auth}"]
        def m(d): d.setdefault("mcpServers", {})["persistence"] = {"command": npx, "args": args}
        merge(cd, m)
        print("✓ Claude Desktop configured")
    else:
        print("· Claude Desktop skipped (config not found)")

# Antigravity (Gemini) — uses serverUrl + headers
if want("antigravity"):
    ag = home / ".gemini/config/mcp_config.json"
    if ag.parent.exists() or ag.exists():
        srv = {"serverUrl": url}
        if token: srv["headers"] = {"Authorization": auth}
        merge(ag, lambda d: d.setdefault("mcpServers", {}).__setitem__("persistence", srv))
        print("✓ Antigravity configured")
    else:
        print("· Antigravity skipped (~/.gemini not found)")

# ollmcp — servers-json
if want("ollmcp"):
    oj = home / ".persistence/ollmcp-servers.json"
    srv = {"type": "streamable_http", "url": url}
    if token: srv["headers"] = {"Authorization": auth}
    merge(oj, lambda d: d.setdefault("mcpServers", {}).__setitem__("persistence", srv))
    print(f"✓ ollmcp configured ({oj})")
PY

echo
echo "Done. Restart Claude Desktop / Antigravity to pick up changes."
echo "Claude Code: run 'claude mcp list' to verify."
