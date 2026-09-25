<#
  sync-sharee-firewall.ps1 -- keep tailnet SHAREES (devices of other accounts
  that ai-server is shared with: Antoine's pp-vps and Mac) limited to the ports
  Tai granted them, as their IPs come and go.

  Sharees may reach:  TCP 1234 (LM Studio inference)
                      TCP 2222 (SSH into the developer's WSL environment; up only in sessions)
                      TCP 8899 (forwarded into that environment, e.g. the developer's own relay)
  Everything else from a sharee IP is blocked (SSH, ComfyUI, Sunshine, model
  proxy, DNS filter, ...). Windows Firewall block rules beat allow rules, so the
  existing Tailscale-In / AI-* allows cannot reopen them.

  Also writes state\ai-admin\sharee-ips.json, the relay's client allowlist.
  Runs from the \AI-ShareeFirewall task (SYSTEM, at boot + every 10 min).
#>
$ErrorActionPreference = 'Stop'
$ts = 'C:\Program Files\Tailscale\tailscale.exe'
$out = 'C:\AI-Server\state\ai-admin\sharee-ips.json'
$log = 'C:\AI-Server\logs\sharee-firewall.log'

$st = & $ts status --json | ConvertFrom-Json
$ips = @($st.Peer.PSObject.Properties.Value |
         Where-Object { $_.ShareeNode } |
         ForEach-Object { $_.TailscaleIPs } |
         Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Sort-Object -Unique)

[IO.File]::WriteAllText($out, (@{ ips = $ips; updated = (Get-Date).ToString('s') } | ConvertTo-Json -Compress))

$rules = @(
  @{ Name = 'AI-Sharee-Block-TCP'; Protocol = 'TCP'; Action = 'Block'; LocalPort = @('1-1233', '1235-2221', '2223-8898', '8900-65535') },
  @{ Name = 'AI-Sharee-Block-UDP'; Protocol = 'UDP'; Action = 'Block'; LocalPort = @('1-65535') },
  @{ Name = 'AI-Sharee-Allow';     Protocol = 'TCP'; Action = 'Allow'; LocalPort = @('1234', '2222', '8899') }
)
foreach ($r in $rules) {
  $existing = Get-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue
  if (-not $ips) {
    if ($existing) { Disable-NetFirewallRule -Name $r.Name }
    continue
  }
  if (-not $existing) {
    New-NetFirewallRule -Name $r.Name -DisplayName $r.Name -Direction Inbound -Protocol $r.Protocol `
      -LocalPort $r.LocalPort -RemoteAddress $ips -Action $r.Action -Profile Any | Out-Null
  } else {
    Set-NetFirewallRule -Name $r.Name -RemoteAddress $ips -LocalPort $r.LocalPort -Enabled True
  }
}
"$((Get-Date).ToString('s')) sharees: $($ips -join ', ')" | Add-Content $log
