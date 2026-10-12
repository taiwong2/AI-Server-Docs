$ErrorActionPreference = 'Stop'
$R = "$env:USERPROFILE\deepseek-harness"
$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
# 1. keys: user-only ACL
foreach ($k in "$env:USERPROFILE\.config\ai-server-2\llm_api_key") {   # (AI Server 1 model-proxy key dropped 2026-10-12: AS1 serves no LLM)
  icacls $k /inheritance:r /grant:r "${me}:F" | Out-Null
  icacls $k | Select-Object -First 2
}
# 2. ssh alias
$cfg = "$env:USERPROFILE\.ssh\config"
if (-not (Select-String -Path $cfg -Pattern '^\s*Host\s+ai-server-2\s*$' -Quiet)) {
  Copy-Item $cfg "$cfg.bak-20261011-dsh"
  Add-Content -Path $cfg -Encoding ASCII -Value "`r`nHost ai-server-2`r`n  HostName 100.65.60.112`r`n  User taiwong`r`n  IdentityFile ~/.ssh/id_ed25519`r`n  ServerAliveInterval 30"
  'ssh alias ai-server-2 added'
}
# 3. shims on PATH (C:\Users\<you>\bin is already on the user PATH)
$bin = "$env:USERPROFILE\bin"
New-Item -ItemType Directory -Force $bin | Out-Null
if ((Test-Path "$bin\dsh.cmd") -and -not (Test-Path "$bin\dsh.cmd.bak-20261011-localmode")) { Copy-Item "$bin\dsh.cmd" "$bin\dsh.cmd.bak-20261011-localmode" }
Copy-Item "$R\bin\dsh.cmd", "$R\bin\dsh-llm-mode.cmd" $bin -Force
# 4. proxy autostart: per-user logon task, hidden (wscript), restart on failure
$act = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wscript.exe" -Argument "//B //Nologo `"$R\bin\dsh-proxy.vbs`""
$trg = New-ScheduledTaskTrigger -AtLogOn -User $me
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
  -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
$pri = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName 'DSH Proxy' -Action $act -Trigger $trg -Settings $set -Principal $pri -Description 'DeepSeek Harness model proxy on 127.0.0.1:1235 (deepseek-harness\bin\dsh-proxy.mjs)' -Force | Out-Null
Start-ScheduledTask -TaskName 'DSH Proxy'
Start-Sleep 3
Get-ScheduledTask -TaskName 'DSH Proxy' | Select-Object TaskName, State | Format-List | Out-String
Get-NetTCPConnection -LocalPort 1235 -State Listen -ErrorAction SilentlyContinue | Select-Object LocalAddress, LocalPort, OwningProcess | Format-List | Out-String
