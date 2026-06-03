<#
  Wire Windows-hosted MCP clients to a Persistence server.

    scripts\connect-client.ps1 -Url http://192.168.1.50:8077/mcp -Token <TOKEN>
    scripts\connect-client.ps1 -Url http://localhost:8077/mcp           # token from %USERPROFILE%\.persistence\token.txt
    scripts\connect-client.ps1 -Url ... -Clients claude-code,claude-desktop

  Clients: claude-code, claude-desktop, antigravity, ollmcp (default: all).
  Configures only clients that are present. Re-runnable.
#>
param(
    [Parameter(Mandatory=$true)][string]$Url,
    [string]$Token = "",
    [string]$Clients = "all"
)
$ErrorActionPreference = "Stop"

$tokFile = Join-Path $env:USERPROFILE ".persistence\token.txt"
if (-not $Token -and (Test-Path $tokFile)) { $Token = (Get-Content $tokFile -Raw).Trim() }
$auth = "Bearer $Token"
function Want($n) { return ($Clients -eq "all") -or (($Clients -split ",") -contains $n) }

function Merge-JsonServer($path, $serverObj) {
    $dir = Split-Path $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $data = @{}
    if ((Test-Path $path) -and (Get-Item $path).Length -gt 0) {
        $data = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
    }
    if (-not $data.ContainsKey("mcpServers")) { $data["mcpServers"] = @{} }
    $data["mcpServers"]["persistence"] = $serverObj
    ($data | ConvertTo-Json -Depth 10) | Set-Content -Path $path
}

# Claude Code
if ((Want "claude-code") -and (Get-Command claude -ErrorAction SilentlyContinue)) {
    claude mcp remove persistence -s user 2>$null | Out-Null
    if ($Token) {
        claude mcp add --transport http --scope user persistence $Url --header "Authorization: $auth" | Out-Null
    } else {
        claude mcp add --transport http --scope user persistence $Url | Out-Null
    }
    Write-Host "OK Claude Code configured"
} elseif (Want "claude-code") { Write-Host "-- Claude Code skipped (claude CLI not found)" }

# Claude Desktop
if (Want "claude-desktop") {
    $cd = Join-Path $env:APPDATA "Claude\claude_desktop_config.json"
    if (Test-Path $cd) {
        $args = @("-y", "mcp-remote", $Url)
        if ($Token) { $args += @("--header", "Authorization: $auth") }
        Merge-JsonServer $cd @{ command = "npx"; args = $args }
        Write-Host "OK Claude Desktop configured"
    } else { Write-Host "-- Claude Desktop skipped (config not found)" }
}

# Antigravity
if (Want "antigravity") {
    $ag = Join-Path $env:USERPROFILE ".gemini\config\mcp_config.json"
    $srv = @{ serverUrl = $Url }
    if ($Token) { $srv["headers"] = @{ Authorization = $auth } }
    Merge-JsonServer $ag $srv
    Write-Host "OK Antigravity configured"
}

# ollmcp
if (Want "ollmcp") {
    $oj = Join-Path $env:USERPROFILE ".persistence\ollmcp-servers.json"
    $srv = @{ type = "streamable_http"; url = $Url }
    if ($Token) { $srv["headers"] = @{ Authorization = $auth } }
    Merge-JsonServer $oj $srv
    Write-Host "OK ollmcp configured ($oj)"
}

Write-Host "`nDone. Restart Claude Desktop / Antigravity to pick up changes."
