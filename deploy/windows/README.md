# Running Persistence on Windows (permanent host)

This sets up the server as an always-on, auto-starting service on a Windows
workstation, reachable by other devices on your LAN.

## 1. Prerequisites

- **Python 3.11+** — https://python.org (check "Add python.exe to PATH" during install).
- **Ollama for Windows** — https://ollama.com/download, then pull the model:
  ```powershell
  ollama pull nomic-embed-text
  ```

## 2. Install

Open **PowerShell as Administrator** (needed for the firewall rule + scheduled task):

```powershell
git clone https://github.com/sjsam/Persistence.git
cd Persistence
powershell -ExecutionPolicy Bypass -File deploy\windows\install.ps1
```

The script creates a venv at `%USERPROFILE%\.persistence\venv`, generates an auth
token, opens TCP 8077 on the Private firewall profile, registers a startup task,
starts the server, and prints the **LAN URL + token** for your clients.

## 3. Migrate existing memories from the Mac (optional)

Your data is a single SQLite file. To carry over what you saved on the Mac, copy it
**before first run** (or stop the task, copy, restart). Same embedding model
(`nomic-embed-text`) on both machines, so the stored vectors stay valid.

```
# on the Mac:
~/.persistence/memory.db

# copy to, on Windows:
%USERPROFILE%\.persistence\memory.db
```

(`scp`, a USB stick, or any file copy works.)

## 4. Find the LAN address

```powershell
ipconfig            # note the IPv4 address, e.g. 192.168.1.50
hostname            # e.g. WORKSTATION
```

**Strongly recommended:** give this machine a **static IP** or a **DHCP
reservation** in your router, so the address never changes. Clients point at
`http://<that-ip>:8077/mcp`.

> Windows hostnames (`WORKSTATION.local`) only resolve from other devices if an
> mDNS responder is present (macOS/Linux have one; Bonjour adds it on Windows).
> A static IP is the reliable choice.

## Managing the service

```powershell
schtasks /Run    /TN "Persistence"     # start now
schtasks /End    /TN "Persistence"     # stop
schtasks /Query  /TN "Persistence"     # status
Get-Content $env:USERPROFILE\.persistence\token.txt   # show the token
```

## Uninstall

```powershell
schtasks /Delete /TN "Persistence" /F
netsh advfirewall firewall delete rule name="Persistence MCP 8077"
Remove-Item -Recurse $env:USERPROFILE\.persistence   # WARNING: deletes the database too
```
