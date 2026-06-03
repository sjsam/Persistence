<#
  Persistence — Windows installer.

  Run from the cloned repo root in an *elevated* PowerShell (Run as Administrator,
  needed for the firewall rule + scheduled task):

      git clone https://github.com/sjsam/Persistence.git
      cd Persistence
      powershell -ExecutionPolicy Bypass -File deploy\windows\install.ps1

  What it does:
    1. Creates a standalone venv at %USERPROFILE%\.persistence\venv and installs the package.
    2. Generates a shared auth token (token.txt) if one doesn't exist.
    3. Opens TCP 8077 on the Private firewall profile (LAN only).
    4. Registers a Scheduled Task that runs the server at startup (whether logged on or not).
  Prereqs: Python 3.11+ and Ollama installed, with: ollama pull nomic-embed-text
#>

$ErrorActionPreference = "Stop"
$Base = Join-Path $env:USERPROFILE ".persistence"
$RepoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
New-Item -ItemType Directory -Force -Path $Base | Out-Null

Write-Host "==> Creating venv at $Base\venv and installing..." -ForegroundColor Cyan
python -m venv "$Base\venv"
& "$Base\venv\Scripts\python.exe" -m pip install --quiet --upgrade pip
& "$Base\venv\Scripts\pip.exe" install --quiet "$RepoRoot"

# Token: generate a URL-safe 32-byte token if not already present
$TokFile = Join-Path $Base "token.txt"
if (-not (Test-Path $TokFile)) {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $tok = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
    Set-Content -NoNewline -Path $TokFile -Value $tok
    Write-Host "==> Generated new token" -ForegroundColor Green
} else {
    Write-Host "==> Reusing existing token.txt" -ForegroundColor Yellow
}
Write-Host ("    TOKEN: " + (Get-Content $TokFile))

# Copy the launcher next to the venv so the scheduled task has a stable path
Copy-Item "$PSScriptRoot\run-persistence.cmd" "$Base\run-persistence.cmd" -Force

Write-Host "==> Opening firewall TCP 8077 (Private profile)..." -ForegroundColor Cyan
netsh advfirewall firewall delete rule name="Persistence MCP 8077" 2>$null | Out-Null
netsh advfirewall firewall add rule name="Persistence MCP 8077" dir=in action=allow `
    protocol=TCP localport=8077 profile=private | Out-Null

Write-Host "==> Registering startup task 'Persistence'..." -ForegroundColor Cyan
schtasks /Create /TN "Persistence" /TR "\"$Base\run-persistence.cmd\"" `
    /SC ONSTART /RU "$env:USERNAME" /RL HIGHEST /F | Out-Null
schtasks /Run /TN "Persistence" | Out-Null

Start-Sleep -Seconds 4
Write-Host "==> Health check..." -ForegroundColor Cyan
$tok = Get-Content $TokFile
try {
    $r = Invoke-RestMethod -Uri "http://localhost:8077/healthz" `
        -Headers @{ Authorization = "Bearer $tok" }
    Write-Host ("    OK: " + ($r | ConvertTo-Json -Compress)) -ForegroundColor Green
} catch {
    Write-Host "    Health check failed — see logs / check Ollama is running." -ForegroundColor Red
}

$ip = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.PrefixOrigin -ne 'WellKnown' -and $_.IPAddress -ne '127.0.0.1' } |
        Select-Object -First 1).IPAddress
Write-Host ""
Write-Host "Done. Other LAN devices connect to:  http://$ip`:8077/mcp" -ForegroundColor Cyan
Write-Host "Send header:  Authorization: Bearer <token above>"
