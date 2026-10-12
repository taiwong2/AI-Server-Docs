# dsh-llm-mode.ps1: Windows port of bin/dsh-llm-mode (the client side of AI Server 2's LLM mode, used by dsh.cmd).
#
#   dsh-llm-mode on       wake AI Server 2 if asleep, `llm-mode on` there (moves its Clash jobs off, loads Flash-Next),
#                         wait until the model answers; prints one status line (progress lines dimmed)
#   dsh-llm-mode touch    "a dsh session is alive": resets the 30 min idle unload timer on the box
#   dsh-llm-mode status   llm-mode status on the box
#   dsh-llm-mode off      unload now and give the box back to the Clash jobs
# Internal (used by dsh.cmd):
#   session <flagfile>    exit 3 unless stdin and stdout are a console; else `on`, create <flagfile> and start a hidden
#                         keepalive that touches every 5 min until <flagfile> is deleted or the calling shell exits
#   keepalive <flagfile> <pid>
# Env: AIS2_HOST (ssh alias, default ai-server-2). Wake: magic packet when this PC is on the box's LAN
# (192.168.10.x), then retry ssh up to AIS2_WAIT_S (default 1500 s; the box also wakes on its 20 min RTC heartbeat).
# Never prints the API key; the model is reached through the local proxy (bin\dsh-proxy.mjs).
param([string]$Cmd = 'status', [string]$Arg1, [string]$Arg2)
$ErrorActionPreference = 'Continue'
$HostAlias = if ($env:AIS2_HOST) { $env:AIS2_HOST } else { 'ai-server-2' }
$SshOpts = @('-n', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=2', $HostAlias)
$ReadyS = if ($env:DSH_READY_S) { [int]$env:DSH_READY_S } else { 180 }   # longest wait for the model, then dsh starts anyway
$Me = $MyInvocation.MyCommand.Path
$ModeF = Join-Path $env:USERPROFILE '.config\ai-server-2\llm-mode.json'   # read by dsh-proxy.mjs: fresh = flash-next only to AS2
function Mark {
  New-Item -ItemType Directory -Force (Split-Path $ModeF) | Out-Null
  $ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  [IO.File]::WriteAllText($ModeF, "{`"ts`": $ms}`n")
}

function Say([string]$m) { [Console]::Error.WriteLine($m) }
function Dim([string]$m) {
  if ([Console]::IsErrorRedirected) { [Console]::Error.WriteLine($m); return }
  $c = [Console]::ForegroundColor; [Console]::ForegroundColor = 'DarkGray'; [Console]::Error.WriteLine($m); [Console]::ForegroundColor = $c
}
# Every ssh call is bounded (a stalled key exchange or a console-stdin read hung dsh for 15 min on 2026-10-12):
# ssh -n, stdout/stderr to temp files, killed after $Sec seconds. Returns @{rc; out}.
function SshRun([string[]]$Remote, [int]$Sec = 20) {
  $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
  try {
    $p = Start-Process -FilePath ssh -ArgumentList ($SshOpts + $Remote) -NoNewWindow -PassThru `
      -RedirectStandardOutput $o -RedirectStandardError $e
    $null = $p.Handle
    if (-not $p.WaitForExit($Sec * 1000)) { try { $p.Kill() } catch {}; return @{ rc = 124; out = '' } }
    return @{ rc = $p.ExitCode; out = (Get-Content -Raw -LiteralPath $o) }
  } finally { Remove-Item -LiteralPath $o, $e -ErrorAction SilentlyContinue }
}
function SshOk { return ((SshRun @('true') 20).rc -eq 0) }
function Status { try { return ((SshRun @('llm-mode', 'status', '--json') 25).out | ConvertFrom-Json) } catch { return $null } }

function Send-MagicPacket {
  $lan = '192.168.10.'
  $mine = [Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName()) | Where-Object { $_.ToString().StartsWith($lan) }
  if (-not $mine) { return }
  $macs = @('cc:61:46:b6:34:c5', '38:05:25:31:90:8a', '38:05:25:31:90:8b')   # wlp99s0, enp97s0, enp98s0
  $udp = New-Object Net.Sockets.UdpClient; $udp.EnableBroadcast = $true
  try {
    foreach ($mac in $macs) {
      $b = $mac.Split(':') | ForEach-Object { [Convert]::ToByte($_, 16) }
      $pkt = [byte[]](@(0xFF) * 6 + (1..16 | ForEach-Object { $b }))
      foreach ($dst in @('192.168.10.255', '255.255.255.255', '192.168.10.9')) { foreach ($port in 9, 7) {
        try { [void]$udp.Send($pkt, $pkt.Length, $dst, $port) } catch {} } }
    }
  } finally { $udp.Close() }
}

function Wake {
  if (SshOk) { return $true }
  Dim 'dsh: AI Server 2 is asleep, waking it (can take a few minutes)'
  Send-MagicPacket
  $wait = if ($env:AIS2_WAIT_S) { [int]$env:AIS2_WAIT_S } else { 1500 }
  $deadline = (Get-Date).AddSeconds($wait)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 10
    if (SshOk) { return $true }
    Send-MagicPacket
  }
  return $false
}

function On {
  $t0 = Get-Date
  if (-not (Wake)) { Remove-Item -LiteralPath $ModeF -ErrorAction SilentlyContinue
    Say "dsh: AI Server 2 unreachable; this session uses AI Server 1's Flash-Next (fallback)"; return 1 }
  $st = Status
  if ($st -and $st.model -eq 'up' -and $st.on -eq $true) {
    [void](SshRun @('llm-mode', 'touch') 20); Mark
    Say "dsh: Flash-Next on AI Server 2 (LLM mode on since $($st.since))"
    return 0
  }
  Dim "dsh: LLM mode on AI Server 2: moving its Clash jobs off and loading Flash-Next (waiting up to $ReadyS s)"
  if ((SshRun @('llm-mode', 'on', '--detach') 30).rc -ne 0) { Dim '  (could not start llm-mode on; still polling)' }
  while ($true) {
    Start-Sleep -Seconds 10
    $el = [int]((Get-Date) - $t0).TotalSeconds
    $st = Status
    if ($st -and $st.model -eq 'up' -and $st.on -eq $true) { Mark; Say "dsh: Flash-Next on AI Server 2 ready ($el s)"; return 0 }
    if ($st) { $ll = "$($st.last_log)"; if ($ll.Length -gt 90) { $ll = $ll.Substring(0, 90) }
      Dim "  ${el}s: model $($st.model), MemAvailable $($st.mem_available_gb) GB; $ll" }
    else { Dim "  ${el}s: no answer from AI Server 2 (retrying)" }
    if ($el -ge $ReadyS) {
      Remove-Item -LiteralPath $ModeF -ErrorAction SilentlyContinue
      Say "dsh: Flash-Next on AI Server 2 not ready after $el s; starting on the fallback (AI Server 1). AI Server 2 keeps loading and takes over when up. Details: ssh $HostAlias llm-mode status"
      return 1
    }
  }
}

function Touch { if ((SshRun @('llm-mode', 'touch') 25).rc -eq 0) { Mark } }

switch ($Cmd) {
  'on'     { exit (On) }
  'touch'  { Touch; exit 0 }
  'status' { $r = SshRun @('llm-mode', 'status') 30; [Console]::Out.Write($r.out); exit $r.rc }
  'off'    { Remove-Item -LiteralPath $ModeF -ErrorAction SilentlyContinue; $r = SshRun @('llm-mode', 'off') 90; [Console]::Out.Write($r.out); exit $r.rc }
  'session' {
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { exit 3 }
    [void](On)
    $shell = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId   # the cmd.exe running dsh.cmd
    Set-Content -LiteralPath $Arg1 -Value $shell -Encoding ASCII
    Start-Process -WindowStyle Hidden -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
      -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$Me`"", 'keepalive', "`"$Arg1`"", "$shell")
    exit 0
  }
  'keepalive' {
    $flag = $Arg1; $shell = [int]$Arg2; $next = (Get-Date).AddMinutes(5)
    while ((Test-Path -LiteralPath $flag) -and (Get-Process -Id $shell -ErrorAction SilentlyContinue)) {
      Start-Sleep -Seconds 2
      if ((Get-Date) -ge $next) { Touch; $next = (Get-Date).AddMinutes(5) }
    }
    Remove-Item -LiteralPath $flag -ErrorAction SilentlyContinue
    Touch   # final touch at exit, like the Mac wrapper
    exit 0
  }
  default { Say 'usage: dsh-llm-mode on|touch|status|off'; exit 2 }
}
