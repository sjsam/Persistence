# Running Persistence in WSL2 (your permanent home)

Inside WSL, Persistence is just the **Linux** install. The only WSL-specific work
is (a) enabling systemd, (b) making the server reachable from other LAN devices
(WSL2 runs in a NAT'd VM), and (c) starting WSL at Windows login.

## 1. Enable systemd in WSL

In WSL, edit `/etc/wsl.conf`:

```ini
[boot]
systemd=true
```

Then, from **Windows** PowerShell, restart WSL:

```powershell
wsl --shutdown
```

Reopen WSL. Confirm with `systemctl is-system-running` (should be `running`/`degraded`).

## 2. Install the server (inside WSL)

```bash
sudo apt update && sudo apt install -y python3-venv python3-pip curl
# Ollama: install inside WSL, OR point OLLAMA_URL at the Windows host's Ollama.
curl -fsSL https://ollama.com/install.sh | sh
ollama pull nomic-embed-text

git clone https://github.com/sjsam/Persistence.git
cd Persistence
bash deploy/linux/install.sh
```

This installs to `~/.persistence/venv` and runs the server as a systemd **user**
service, bound to `0.0.0.0:8077` with token auth. It prints the token.

> Carry over Mac data first if you want it: copy `~/.persistence/memory.db` from
> the Mac into WSL's `~/.persistence/memory.db` (and `token.txt` to keep the same
> token) **before** running install.sh.

## 3. LAN access — pick ONE

WSL2 has its own internal IP, so other devices can't reach it directly by default.

### Option A — Mirrored networking (Windows 11 22H2+, simplest)

Create `%USERPROFILE%\.wslconfig` on **Windows**:

```ini
[wsl2]
networkingMode=mirrored
```

`wsl --shutdown` and reopen. WSL now shares the Windows host's IP — other devices
reach the server at `http://<windows-lan-ip>:8077/mcp`. Open the firewall once
(elevated PowerShell):

```powershell
netsh advfirewall firewall add rule name="Persistence MCP 8077" dir=in action=allow protocol=TCP localport=8077 profile=private
```

### Option B — Port proxy (older Windows / NAT mode)

WSL2's internal IP changes on each boot, so forward the Windows host port to it and
refresh on login. Run **`wsl-portproxy.ps1`** (in this folder) from an **elevated**
PowerShell — it queries the current WSL IP, resets the `netsh` portproxy, and opens
the firewall:

```powershell
powershell -ExecutionPolicy Bypass -File deploy\wsl\wsl-portproxy.ps1
```

To survive reboots, register it at logon (elevated):

```powershell
schtasks /Create /TN "Persistence-WSL-portproxy" /SC ONLOGON /RL HIGHEST /F ^
  /TR "powershell -ExecutionPolicy Bypass -File %USERPROFILE%\Persistence\deploy\wsl\wsl-portproxy.ps1"
```

Other devices then reach `http://<windows-lan-ip>:8077/mcp`.

## 4. Start WSL automatically at Windows login

WSL (and its systemd service) only run while the distro is up. Launch it at logon
with a scheduled task (elevated PowerShell; replace `Ubuntu` with your distro from
`wsl -l -q`):

```powershell
schtasks /Create /TN "Persistence-WSL-boot" /SC ONLOGON /RL HIGHEST /F ^
  /TR "wsl.exe -d Ubuntu -u %USERNAME% -e true"
```

This boots the distro (and systemd + the Persistence service) shortly after login;
the distro stays running in the background.

## Manage / verify

```bash
# inside WSL
systemctl --user status persistence
curl -H "Authorization: Bearer $(cat ~/.persistence/token.txt)" http://localhost:8077/healthz
```
