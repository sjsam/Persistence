#!/usr/bin/env bash
#
# Persistence — macOS installer (launchd, auto-start on login).
#
#   git clone https://github.com/sjsam/Persistence.git
#   cd Persistence
#   bash deploy/macos/install.sh
#
# Installs a standalone venv at ~/.persistence/venv (NOT in ~/Documents — macOS
# TCC blocks launchd from reading it there), generates a token, and loads a
# launchd agent bound to the LAN with token auth.
#
# Prereqs: Python 3.11+, Ollama running with: ollama pull nomic-embed-text
set -euo pipefail

BASE="$HOME/.persistence"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLIST="$HOME/Library/LaunchAgents/com.persistence.server.plist"
mkdir -p "$BASE" "$HOME/Library/LaunchAgents"

echo "==> Creating venv and installing from $REPO_ROOT ..."
python3 -m venv "$BASE/venv"
"$BASE/venv/bin/pip" install -q --upgrade pip
"$BASE/venv/bin/pip" install -q "$REPO_ROOT"

TOK="$BASE/token.txt"
if [ ! -f "$TOK" ]; then
    python3 -c "import secrets; print(secrets.token_urlsafe(32))" > "$TOK"
    chmod 600 "$TOK"
    echo "==> Generated new token"
else
    echo "==> Reusing existing token.txt"
fi
TOKEN="$(cat "$TOK")"

echo "==> Rendering launchd agent ..."
sed -e "s|__VENV__|$BASE/venv/bin/persistence-server|g" \
    -e "s|__TOKEN__|$TOKEN|g" \
    "$REPO_ROOT/deploy/macos/com.persistence.server.plist" > "$PLIST"

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
launchctl start com.persistence.server

echo "==> Health check ..."
for _ in $(seq 1 10); do
    if curl -fsS -H "Authorization: Bearer $TOKEN" http://localhost:8077/healthz >/dev/null 2>&1; then
        echo "    OK"; break
    fi
    sleep 1
done

IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo '<this-mac-ip>')"
echo
echo "Done. Token: $TOKEN"
echo "LAN URL for other devices:  http://$IP:8077/mcp"
echo "Wire clients:  bash scripts/connect-client.sh --url http://$IP:8077/mcp --token $TOKEN"
