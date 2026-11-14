<#
as1-qwen27b.ps1 - Qwen3.8 27B (uncensored, Q4_K_M + vision) on both 3090s for dsh (user request 2026-11-13:
"can we load qwen 3.8 27b on it and then run dsh on it. that way ai server 2 is free"; Strata cannot run the dense
27B, so llama.cpp, option C). Needs the AS1 LLM override C:\AI-Server\state\as1-llm.allowed (docs/24).

  -Action Run     supervisor (what task \AI-Qwen27B runs): holds a GPU lease on each card, keeps llama-server up,
                  restarts it if it dies, exits when the stop flag appears or the override file is removed.
  -Action Stop    stop flag + kill server and supervisor, release the leases. The task stays registered;
                  `Disable-ScheduledTask AI-Qwen27B` keeps it off across reboots.
  -Action Status  JSON: supervisor/server pids, leases, health.

Endpoint: http://100.71.113.77:1241/v1 (tailnet only, Bearer key in state\qwen27b\api_key), model id
qwen3.8-27b-uncensored (aliases qwen3.8-27b-as1, qwen3.8-27b-strata).
#>
param([ValidateSet('Run','Start','Stop','Status')][string]$Action = 'Status')
. 'C:\AI-Server\scripts\as1-llm-policy.ps1'
$ErrorActionPreference = 'Stop'
$root    = 'C:\AI-Server'
$python  = 'C:\Users\poopl\miniconda3\python.exe'
$lease   = Join-Path $root 'scripts\gpulease.py'
$stDir   = Join-Path $root 'state\qwen27b'
$logDir  = Join-Path $root 'logs\qwen27b'
$stPath  = Join-Path $stDir 'state.json'
$stopFlag= Join-Path $stDir 'stop'
$keyFile = Join-Path $stDir 'api_key'
$exe     = 'C:\AI-Server\tools\llama-inovello\build\bin\llama-server.exe'
$mdir    = 'C:\AI-Server\models\gguf\orcarouter\Qwen3.8-27B-Uncensored-GGUF'
$model   = Join-Path $mdir 'orcarouter_Qwen3.8-27B-Uncensored-Q4_K_M.gguf'
$mmproj  = Join-Path $mdir 'mmproj-orcarouter_Qwen3.8-27B-Uncensored-f16.gguf'
$hostIp  = '100.71.113.77'
$port    = 1241
$ctx     = 262144
$parallel= 2
$leaseMb = 21000
New-Item -ItemType Directory -Force $stDir,$logDir | Out-Null
function Log([string]$m){ Add-Content -Path (Join-Path $logDir 'supervisor.log') -Value "$(Get-Date -Format s) $m" }
function Read-St { if(Test-Path $stPath){ Get-Content -Raw $stPath | ConvertFrom-Json } }
function Write-St($o){ $o | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $stPath }
function Alive([int]$id){ try { -not (Get-Process -Id $id -EA Stop).HasExited } catch { $false } }
function Healthy { try { (Invoke-WebRequest -UseBasicParsing -Uri "http://${hostIp}:$port/health" -TimeoutSec 5).StatusCode -eq 200 } catch { $false } }
function Release($ids){ foreach($i in @($ids)){ if($i){ & $python $lease release $i 2>$null | Out-Null } } }
function Kill-Server { Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" | Where-Object { $_.CommandLine -match "--port $port" } | ForEach-Object { & taskkill.exe /PID $_.ProcessId /T /F | Out-Null } }

if($Action -eq 'Status'){
  $s = Read-St
  $o = [ordered]@{ override=(Test-AS1LlmAllowed); stopFlag=(Test-Path $stopFlag); healthy=(Healthy); state=$s
                   supervisorAlive=($s -and (Alive ([int]$s.supervisorPid))); serverAlive=($s -and $s.serverPid -and (Alive ([int]$s.serverPid))) }
  $o | ConvertTo-Json -Depth 5; exit 0
}
if($Action -eq 'Start'){
  Remove-Item -Force $stopFlag -EA SilentlyContinue
  Enable-ScheduledTask -TaskName 'AI-Qwen27B' | Out-Null; Start-ScheduledTask -TaskName 'AI-Qwen27B'; 'started'; exit 0
}
if($Action -eq 'Stop'){
  New-Item -ItemType File -Force $stopFlag | Out-Null
  $s = Read-St
  if($s -and (Alive ([int]$s.supervisorPid))){ & taskkill.exe /PID ([int]$s.supervisorPid) /T /F | Out-Null }
  Kill-Server
  if($s){ Release $s.leaseIds }
  Log 'STOP requested'; 'stopped'; exit 0
}

# ---- Run (supervisor) ----
Assert-AS1LlmAllowed 'qwen27b Run'
if(Test-Path $stopFlag){ Log 'Run: stop flag present, not starting (use -Action Start)'; exit 0 }
foreach($f in $exe,$model){ if(-not (Test-Path $f)){ Log "missing $f"; throw "missing $f" } }
if(-not (Test-Path $keyFile)){ -join ((48..57)+(97..122) | Get-Random -Count 40 | ForEach-Object {[char]$_}) | Set-Content -NoNewline -Encoding ascii $keyFile }
Kill-Server
$ids = @()
try {
  foreach($gpu in 0,1){
    $ErrorActionPreference='Continue'
    $line = (& $python $lease acquire --vram $leaseMb --gpu $gpu --job qwen27b-dsh --timeout 3600 --max-hold 31536000 --pid $PID 2>$null | Where-Object { $_ -match '^\d+\s+\S+' } | Select-Object -First 1)
    $ErrorActionPreference='Stop'
    if(-not $line){ throw "GPU lease failed for GPU $gpu" }
    $ids += (($line -split '\s+')[1])
  }
  Log "leases $($ids -join ',')"
  $a = @('--model',$model,'--host',$hostIp,'--port',"$port",'--api-key-file',$keyFile,
         '--alias','qwen3.8-27b-uncensored,qwen3.8-27b-as1,qwen3.8-27b-strata',
         '--n-gpu-layers','all','--split-mode','tensor','--tensor-split','1,1',
         '--ctx-size',"$ctx",'--parallel',"$parallel",'--kv-unified','--flash-attn','on',
         '--cache-type-k','q8_0','--cache-type-v','q8_0','--batch-size','2048','--ubatch-size','512',
         '--threads','8','--threads-batch','16','--cache-ram','8192','--jinja','--metrics','--slots',
         '--spec-type','draft-mtp','--spec-draft-n-max','2')
  if(Test-Path $mmproj){ $a += @('--mmproj',$mmproj,'--image-min-tokens','1024') }
  $restarts = 0
  while($true){
    if((Test-Path $stopFlag) -or -not (Test-AS1LlmAllowed)){ Log 'stop flag or override removed'; break }
    $p = Start-Process -FilePath $exe -ArgumentList $a -WindowStyle Hidden -PassThru `
           -RedirectStandardOutput (Join-Path $logDir 'server.log') -RedirectStandardError (Join-Path $logDir 'server.err.log')
    Write-St ([pscustomobject]@{ supervisorPid=$PID; serverPid=$p.Id; leaseIds=$ids; port=$port; ctx=$ctx; parallel=$parallel; startedAt=(Get-Date).ToString('o'); restarts=$restarts })
    Log "server pid $($p.Id) started (restart $restarts)"
    while(-not $p.HasExited){
      if((Test-Path $stopFlag) -or -not (Test-AS1LlmAllowed)){ break }
      Start-Sleep 10
    }
    if(-not $p.HasExited){ Kill-Server; Log 'server stopped by flag'; break }
    Log "server exited code $($p.ExitCode)"
    $restarts++
    Start-Sleep ([math]::Min(300, 15 * $restarts))
  }
} finally {
  Kill-Server
  Release $ids
  Log 'supervisor exit, leases released'
}
