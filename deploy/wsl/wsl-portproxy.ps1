<#
  Forward the Windows host's TCP 8077 to the Persistence server running inside
  WSL2 (NAT networking mode). WSL2's internal IP changes on each boot, so this
  re-discovers it and resets the proxy. Run from an ELEVATED PowerShell, and
  register it at logon (see deploy/wsl/README.md) so it survives reboots.

  Not needed if you use mirrored networking mode (Windows 11 22H2+).
#>

$ErrorActionPreference = "Stop"
$Port = 8077

# Current WSL2 IP (first address from `hostname -I`)
$wslIp = (wsl.exe hostname -I).Trim().Split(" ")[0]
if ([string]::IsNullOrWhiteSpace($wslIp)) {
    Write-Error "Could not determine WSL IP. Is the distro running?"
    exit 1
}
Write-Host "WSL IP: $wslIp"

# Reset the portproxy for this port, then point it at the current WSL IP
netsh interface portproxy delete v4tov4 listenport=$Port listenaddress=0.0.0.0 2>$null | Out-Null
netsh interface portproxy add    v4tov4 listenport=$Port listenaddress=0.0.0.0 `
    connectport=$Port connectaddress=$wslIp | Out-Null

# Ensure the inbound firewall rule exists (Private profile = LAN only)
netsh advfirewall firewall delete rule name="Persistence MCP $Port" 2>$null | Out-Null
netsh advfirewall firewall add rule name="Persistence MCP $Port" dir=in action=allow `
    protocol=TCP localport=$Port profile=private | Out-Null

Write-Host "Forwarding 0.0.0.0:$Port -> ${wslIp}:$Port"
netsh interface portproxy show v4tov4
