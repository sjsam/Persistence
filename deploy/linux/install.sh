#!/usr/bin/env bash
#
# Persistence — Linux installer (systemd user service, auto-start at boot).
# Also used inside WSL2 — see deploy/wsl/README.md for WSL networking/autostart.
#
#   git clone https://github.com/sjsam/Persistence.git
#   cd Persistence
#   bash deploy/linux/install.sh
#
# Installs a standalone venv at ~/.persistence/venv, generates a token, and
# enables a systemd user service bound to the LAN with token auth. Enables
# lingering so the service starts at boot without an interactive login.
#
# Prereqs: Python 3.11+ (+ python3-venv), Ollama running with:
#   ollama pull nomic-embed-text
set -euo pipefail

BASE="$HOME/.persistence"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$BASE" "$UNIT_DIR"

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

echo "==> Rendering systemd user unit ..."
sed -e "s|__VENV__|$BASE/venv/bin/persistence-server|g" \
    -e "s|__TOKEN__|$TOKEN|g" \
    "$REPO_ROOT/deploy/linux/persistence.service" > "$UNIT_DIR/persistence.service"

systemctl --user daemon-reload
systemctl --user enable --now persistence.service
# Start at boot without login (no-op/!harmless if not permitted, e.g. some WSL):
loginctl enable-linger "$USER" 2>/dev/null || echo "    (could not enable linger — fine under WSL)"

echo "==> Health check ..."
for _ in $(seq 1 10); do
    if curl -fsS -H "Authorization: Bearer $TOKEN" http://localhost:8077/healthz >/dev/null 2>&1; then
        echo "    OK"; break
    fi
    sleep 1
done

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo "Done. Token: $TOKEN"
echo "LAN URL for other devices:  http://${IP:-<this-host-ip>}:8077/mcp"
echo
echo "Firewall (run the one for your distro if needed):"
echo "  ufw:       sudo ufw allow 8077/tcp"
echo "  firewalld: sudo firewall-cmd --add-port=8077/tcp --permanent && sudo firewall-cmd --reload"
echo
echo "Manage:  systemctl --user {status|restart|stop} persistence"
