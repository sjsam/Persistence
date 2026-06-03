<#
  Persistence - one-command setup (native Windows).

    .\setup.ps1                                   HOST:   install the server, wire local
                                                          tools, print a command others can
                                                          run to connect to this server.
    .\setup.ps1 connect -Url URL [-Token TOK]     CLIENT: wire THIS machine's tools to a
                                                          remote server. Installs nothing.

  Host mode orchestrates the existing pieces: prereq checks, deploy\windows\install.ps1,
  and scripts\connect-client.ps1. (Inside WSL use ./setup.sh instead.)
#>
param(
    [Parameter(Position=0)][string]$Command = "",
    [string]$Url   = "",
    [string]$Token = "",
    [switch]$Elevated   # internal: set on self-relaunch
)
$ErrorActionPreference = "Stop"
$RepoRoot   = $PSScriptRoot
$Port       = if ($env:PERSISTENCE_PORT) { $env:PERSISTENCE_PORT } else { 8077 }
$OllamaUrl  = if ($env:OLLAMA_URL) { $env:OLLAMA_URL } else { "http://localhost:11434" }
$EmbedModel = if ($env:PERSISTENCE_EMBED_MODEL) { $env:PERSISTENCE_EMBED_MODEL } else { "nomic-embed-text" }
$TokFile    = Join-Path $env:USERPROFILE ".persistence\token.txt"

function Lan-Ip {
    $p = Get-NetConnectionProfile |
        Where-Object { $_.IPv4Connectivity -eq 'Internet' } | Select-Object -First 1
    if ($p) {
        return (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $p.InterfaceIndex |
            Select-Object -First 1).IPAddress
    }
    return "<this-host-ip>"
}

function Require-Ollama {
    Write-Host "`n==> Checking Ollama ($OllamaUrl) ..." -ForegroundColor Cyan
    try { $tags = Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -TimeoutSec 5 }
    catch {
        throw "Ollama is not reachable at $OllamaUrl. Install it from https://ollama.com, " +
              "start it, then re-run. (Only embeddings need Ollama.)"
    }
    if ($tags.models.name -match [regex]::Escape($EmbedModel)) {
        Write-Host "    model '$EmbedModel' present"
    } else {
        Write-Host "    pulling '$EmbedModel' ..."
        ollama pull $EmbedModel
    }
}

function Do-Connect {
    if (-not $Url) { throw "connect mode needs -Url http://<host>:$Port/mcp" }
    $tok = $Token
    if (-not $tok -and (Test-Path $TokFile)) { $tok = (Get-Content $TokFile -Raw).Trim() }
    if ($tok) {
        try {
            Invoke-RestMethod -Uri ("{0}/healthz" -f ($Url -replace '/mcp$','')) `
                -Headers @{ Authorization = "Bearer $tok" } -TimeoutSec 5 | Out-Null
            Write-Host "Server reachable at $Url"
        } catch { Write-Host "WARNING: could not reach server - wiring anyway." -ForegroundColor Yellow }
    }
    Write-Host "`n==> Wiring local tools to $Url ..." -ForegroundColor Cyan
    & "$RepoRoot\scripts\connect-client.ps1" -Url $Url -Token $tok
}

function Do-Host {
    # install.ps1 needs admin (firewall + scheduled task) - self-elevate.
    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Administrator rights needed - a UAC prompt will appear..."
        $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Elevated')
        Start-Process powershell.exe -Verb RunAs -ArgumentList $a -Wait
        return
    }

    Write-Host "Persistence setup - host mode (windows), port $Port"
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) { throw "python not found (need 3.11+)." }
    Require-Ollama

    Write-Host "`n==> Installing server (auto-start) ..." -ForegroundColor Cyan
    & "$RepoRoot\deploy\windows\install.ps1"

    $tok = ""
    if (Test-Path $TokFile) { $tok = (Get-Content $TokFile -Raw).Trim() }

    Write-Host "`n==> Wiring local tools to this server ..." -ForegroundColor Cyan
    & "$RepoRoot\scripts\connect-client.ps1" -Url "http://localhost:$Port/mcp" -Token $tok

    $ip = Lan-Ip
    Write-Host ""
    Write-Host "------------------------------------------------------------------------"
    Write-Host " Persistence is running and your local tools are wired."
    Write-Host ""
    Write-Host "   Local URL : http://localhost:$Port/mcp"
    Write-Host "   LAN URL   : http://${ip}:$Port/mcp"
    Write-Host "   Token     : $(if ($tok) { $tok } else { '<none - tokenless>' })"
    Write-Host ""
    Write-Host " To connect tools on ANOTHER machine, clone this repo there and run:"
    Write-Host "   Windows         :  .\setup.ps1 connect -Url http://${ip}:$Port/mcp$(if($tok){" -Token $tok"})"
    Write-Host "   macOS/Linux/WSL :  ./setup.sh connect --url http://${ip}:$Port/mcp$(if($tok){" --token $tok"})"
    Write-Host "------------------------------------------------------------------------"
    if ($Elevated) { Read-Host "Press Enter to close" }
}

switch ($Command) {
    ""        { Do-Host }
    "connect" { Do-Connect }
    default   { throw "unknown command: $Command  (use '' for host, or 'connect')" }
}
