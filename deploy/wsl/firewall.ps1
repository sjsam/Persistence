<#
  Open the Windows firewall so LAN devices can reach the Persistence MCP server
  running inside WSL2 with mirrored networking. SELF-ELEVATING: if not already
  Administrator it relaunches itself via UAC.

    powershell -ExecutionPolicy Bypass -File deploy\wsl\firewall.ps1
    powershell -ExecutionPolicy Bypass -File deploy\wsl\firewall.ps1 -Port 8077
    powershell -ExecutionPolicy Bypass -File deploy\wsl\firewall.ps1 -Remove

  Why two rules: under mirrored networking the WSL vSwitch is gated by the
  *Hyper-V* firewall (default inbound = Block), so a plain inbound rule is not
  enough on its own. We add both the Hyper-V rule (the real gate) and a standard
  inbound rule scoped to the local subnet + Private profile. Idempotent.
#>
param(
    [int]$Port = 8077,
    [switch]$Remove,
    [switch]$NoSetPrivate,
    [switch]$Elevated   # internal: set on the self-relaunch so we know to pause
)
$ErrorActionPreference = "Stop"

# Well-known VMCreatorId for the WSL Hyper-V vSwitch (confirmed on this host).
$WSL_VMCREATOR = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
$RuleName = "PersistenceMCP-$Port"

# Rule identifiers created by earlier manual setup / older docs. We sweep these
# up alongside $RuleName so re-runs (and -Remove) never leave duplicates behind.
$LegacyHyperVNames  = @('PersistenceMCP')
$LegacyDisplayNames = @('Persistence MCP (WSL)', "Persistence MCP $Port")

function Remove-PersistenceRules {
    foreach ($n in (@($RuleName) + $LegacyHyperVNames)) {
        Remove-NetFirewallHyperVRule -Name $n -ErrorAction SilentlyContinue
    }
    Remove-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue
    Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $LegacyDisplayNames -contains $_.DisplayName } |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

# --- self-elevate -----------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Administrator rights needed - a UAC prompt will appear..."
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",
                 '-Port',"$Port",'-Elevated')
    if ($Remove)       { $argList += '-Remove' }
    if ($NoSetPrivate) { $argList += '-NoSetPrivate' }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -Wait
    } catch {
        Write-Error "Elevation was declined or failed: $($_.Exception.Message)"
        exit 1
    }
    exit 0
}

# --- (running elevated from here) -------------------------------------------
if ($Remove) {
    Remove-PersistenceRules
    Write-Host "Removed all Persistence firewall rules for port $Port (incl. legacy names)."
    if ($Elevated) { Read-Host "Press Enter to close" }
    exit 0
}

# Clear any prior Persistence rules (canonical + legacy) before re-adding, so the
# host ends up with exactly one of each regardless of how it was set up before.
Remove-PersistenceRules

# 1) Keep the active LAN off the Public profile (so we never open a Public port).
if (-not $NoSetPrivate) {
    $prof = Get-NetConnectionProfile |
        Where-Object { $_.IPv4Connectivity -eq 'Internet' } | Select-Object -First 1
    if ($prof -and $prof.NetworkCategory -eq 'Public') {
        Set-NetConnectionProfile -InterfaceIndex $prof.InterfaceIndex -NetworkCategory Private
        Write-Host "Set network '$($prof.InterfaceAlias)' to Private."
    }
}

# 2) Hyper-V firewall rule - the gate that actually matters in mirrored mode.
New-NetFirewallHyperVRule -Name $RuleName -DisplayName "Persistence MCP (WSL) $Port" `
    -Direction Inbound -Action Allow -Protocol TCP -LocalPorts $Port `
    -VMCreatorId $WSL_VMCREATOR | Out-Null
Write-Host "Hyper-V firewall rule added (TCP $Port)."

# 3) Standard inbound rule, scoped to the local subnet + Private profile.
New-NetFirewallRule -Name $RuleName -DisplayName "Persistence MCP (WSL) $Port" `
    -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port `
    -Profile Private -RemoteAddress LocalSubnet | Out-Null
Write-Host "Windows firewall rule added (TCP $Port, Private, LocalSubnet)."

# Report the authoritative LAN address other devices should target.
$lan = (Get-NetConnectionProfile |
    Where-Object { $_.IPv4Connectivity -eq 'Internet' } |
    Select-Object -First 1 |
    ForEach-Object { (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $_.InterfaceIndex |
        Select-Object -First 1).IPAddress })
Write-Host ""
if ($lan) { Write-Host "Done. LAN devices can reach:  http://${lan}:$Port/mcp" }
else      { Write-Host "Done. LAN devices can reach this host on port $Port." }

if ($Elevated) { Read-Host "Press Enter to close" }
