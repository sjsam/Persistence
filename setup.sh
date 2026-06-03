#!/usr/bin/env bash
#
# Persistence — one-command setup.
#
#   ./setup.sh                                  HOST:   install the server, wire local
#                                                       tools, print a command others can
#                                                       run to connect to this server.
#   ./setup.sh connect --url URL [--token TOK]  CLIENT: wire THIS machine's tools to a
#                                                       remote Persistence server. No
#                                                       server is installed.
#   ./setup.sh --help
#
# Host mode orchestrates the existing pieces: prereq checks, the per-platform
# installer under deploy/, the WSL firewall opener, and scripts/connect-client.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${PERSISTENCE_PORT:-8077}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
EMBED_MODEL="${PERSISTENCE_EMBED_MODEL:-nomic-embed-text}"

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# Platform: macos | wsl | linux
detect_platform() {
    case "$(uname -s)" in
        Darwin) echo macos ;;
        Linux)
            if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then echo wsl
            else echo linux; fi ;;
        *) die "unsupported platform: $(uname -s)" ;;
    esac
}

# The host's real LAN IPv4 — route-based, so VPN/loopback addresses are skipped.
lan_ip() {
    local ip=""
    case "$(detect_platform)" in
        macos)
            local ifc; ifc="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
            [ -n "$ifc" ] && ip="$(ipconfig getifaddr "$ifc" 2>/dev/null || true)" ;;
        wsl)
            # Under mirrored networking the Windows host owns the LAN IP; ask it.
            ip="$(powershell.exe -NoProfile -Command \
                "(Get-NetConnectionProfile | Where-Object {\$_.IPv4Connectivity -eq 'Internet'} | Select-Object -First 1 | ForEach-Object { (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex \$_.InterfaceIndex | Select-Object -First 1).IPAddress })" \
                2>/dev/null | tr -d '\r' || true)" ;;
        linux)
            ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')" ;;
    esac
    echo "${ip:-<this-host-ip>}"
}

require_ollama() {
    step "Checking Ollama ($OLLAMA_URL) ..."
    if ! curl -fsS "$OLLAMA_URL/api/tags" >/dev/null 2>&1; then
        die "Ollama is not reachable at $OLLAMA_URL.
       Install it from https://ollama.com and start it, then re-run this script.
       (Embeddings require Ollama; nothing else does.)"
    fi
    if curl -fsS "$OLLAMA_URL/api/tags" 2>/dev/null | grep -q "\"$EMBED_MODEL"; then
        say "    model '$EMBED_MODEL' present"
    else
        say "    pulling '$EMBED_MODEL' ..."
        ollama pull "$EMBED_MODEL"
    fi
}

# ---------------------------------------------------------------------------
# connect mode: wire local tools to a remote server, install nothing.
# ---------------------------------------------------------------------------
do_connect() {
    local url="" token=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --url)   url="$2";   shift 2 ;;
            --token) token="$2"; shift 2 ;;
            -h|--help) usage 0 ;;
            *) die "unknown arg: $1" ;;
        esac
    done
    [ -n "$url" ] || die "connect mode needs --url http://<host>:$PORT/mcp"
    if [ -z "$token" ] && [ -f "$HOME/.persistence/token.txt" ]; then
        token="$(cat "$HOME/.persistence/token.txt")"
    fi

    if [ -n "$token" ]; then
        if curl -fsS -H "Authorization: Bearer $token" \
            "${url%/mcp}/healthz" >/dev/null 2>&1; then
            say "Server reachable at $url"
        else
            say "WARNING: could not reach ${url%/mcp}/healthz — wiring anyway."
        fi
    fi

    step "Wiring local tools to $url ..."
    "$REPO_ROOT/scripts/connect-client.sh" --url "$url" ${token:+--token "$token"}
    say ""
    say "Done. Restart Claude Desktop / Antigravity to pick up changes."
}

# ---------------------------------------------------------------------------
# host mode: install + autostart the server, wire local tools, print remote cmd.
# ---------------------------------------------------------------------------
do_host() {
    local plat; plat="$(detect_platform)"
    say "Persistence setup — host mode ($plat), port $PORT"

    command -v python3 >/dev/null 2>&1 || die "python3 not found (need 3.11+)."
    require_ollama

    step "Installing server (auto-start) ..."
    case "$plat" in
        macos)        bash "$REPO_ROOT/deploy/macos/install.sh" ;;
        wsl|linux)    bash "$REPO_ROOT/deploy/linux/install.sh" ;;
    esac

    local token=""
    [ -f "$HOME/.persistence/token.txt" ] && token="$(cat "$HOME/.persistence/token.txt")"

    if [ "$plat" = "wsl" ]; then
        if [ -n "${PERSISTENCE_SKIP_FIREWALL:-}" ]; then
            step "Skipping Windows firewall (PERSISTENCE_SKIP_FIREWALL set)."
        elif command -v powershell.exe >/dev/null 2>&1; then
            step "Opening the Windows firewall for LAN access (a UAC prompt will appear) ..."
            local fw; fw="$(wslpath -w "$REPO_ROOT/deploy/wsl/firewall.ps1")"
            powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$fw" -Port "$PORT" \
                || say "    (firewall step skipped/failed — re-run: powershell.exe -File deploy/wsl/firewall.ps1)"
        fi
    fi

    step "Wiring local tools to this server ..."
    "$REPO_ROOT/scripts/connect-client.sh" \
        --url "http://localhost:$PORT/mcp" ${token:+--token "$token"}

    local ip; ip="$(lan_ip)"
    cat <<EOF

────────────────────────────────────────────────────────────────────────
 Persistence is running and your local tools are wired.

   Local URL : http://localhost:$PORT/mcp
   LAN URL   : http://$ip:$PORT/mcp
   Token     : ${token:-<none — running tokenless>}

 To connect tools on ANOTHER machine, clone this repo there and run:

   macOS/Linux/WSL :  ./setup.sh connect --url http://$ip:$PORT/mcp${token:+ --token $token}
   Windows         :  .\\setup.ps1 connect -Url http://$ip:$PORT/mcp${token:+ -Token $token}
────────────────────────────────────────────────────────────────────────
EOF
}

# ---------------------------------------------------------------------------
case "${1:-}" in
    "")            do_host ;;
    connect)       shift; do_connect "$@" ;;
    -h|--help)     usage 0 ;;
    *)             die "unknown command: $1  (try: ./setup.sh --help)" ;;
esac
