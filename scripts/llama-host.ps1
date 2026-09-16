<#
Native llama.cpp host for the dual-3090 Qwen service.
The process owns two GPU leases while llama-server is alive. Switch changes
the model without dropping the leases; Stop releases both and resumes training.
#>
param(
    [Parameter(Mandatory=$true)][ValidateSet('Start','Switch','Stop','Status')]
    [string]$Action,
    [ValidateSet('qwen3.8-27b-uncensored','authormist-originality','qwen/qwen3.6-27b','gemma4-12b-qat-uncensored-hauhaucs-balanced','gemma-4-31b','muse-glimmer-30b')]
    [string]$Model = 'qwen3.8-27b-uncensored',
    [switch]$Hold
)
$ErrorActionPreference = 'Stop'
$root = 'C:\AI-Server'
$python = 'C:\Users\poopl\miniconda3\python.exe'
$lease = Join-Path $root 'scripts\gpulease.py'
$stateDir = Join-Path $root 'state\llama-host'
$statePath = Join-Path $stateDir 'state.json'
$logDir = Join-Path $root 'logs\llama-host'
$llama = 'C:\Users\poopl\.lmstudio\extensions\backends\llama.cpp-win-x86_64-nvidia-cuda12-avx2-2.39.0\llama-server.exe'

$models = @{
  'qwen3.8-27b-uncensored' = @{ path='C:\Users\poopl\.lmstudio\models\JonathanColetti\Qwen3.8-27B-Uncensored-GGUF\Qwen3.8-27B-Uncensored-Q6_K.gguf'; ctx=262144 }
  'authormist-originality' = @{ path='C:\Users\poopl\.lmstudio\models\mradermacher\authormist-originality-GGUF\authormist-originality.Q8_0.gguf'; ctx=32768 }
  'qwen/qwen3.6-27b' = @{ path='C:\Users\poopl\.lmstudio\models\lmstudio-community\Qwen3.6-27B-GGUF\Qwen3.6-27B-Q4_K_M.gguf'; ctx=262144 }
  'gemma4-12b-qat-uncensored-hauhaucs-balanced' = @{ path='C:\Users\poopl\.lmstudio\models\HauhauCS\Gemma4-12B-QAT-Uncensored-HauhauCS-Balanced\Gemma4-12B-QAT-Uncensored-HauhauCS-Balanced-Q4_K_M.gguf'; ctx=262144 }
  'gemma-4-31b' = @{ path='C:\Users\poopl\.lmstudio\models\lmstudio-community\gemma-4-31B-it-GGUF\gemma-4-31B-it-Q4_K_M.gguf'; ctx=262144 }
  'muse-glimmer-30b' = @{ path='C:\Users\poopl\.lmstudio\models\unsloth\Muse-Glimmer-30B-GGUF\Muse-Glimmer-30B-UD-Q4_K_XL.gguf'; ctx=131072 }
}

function Read-State { if (Test-Path -LiteralPath $statePath) { Get-Content -Raw $statePath | ConvertFrom-Json } }
function Write-State($v) { New-Item -ItemType Directory -Force $stateDir | Out-Null; $tmp=Join-Path $stateDir 'state.tmp'; $v | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $tmp; Move-Item -Force -LiteralPath $tmp -Destination $statePath }
function Alive([int]$processId) { try { $p=Get-Process -Id $processId -ErrorAction Stop; return -not $p.HasExited } catch { return $false } }
function Release-Leases($s) { foreach($id in @($s.leaseIds)) { & $python $lease release $id | Out-Null } }
function Stop-Training {
  @(Get-CimInstance Win32_Process | Where-Object {$_.CommandLine -and $_.CommandLine -match 'supervise-train\.ps1'}) | ForEach-Object { & taskkill.exe /PID ([int]$_.ProcessId) /T /F | Out-Null }
}
function Launch-Native([string]$name) {
  $m=$models[$name]; if(-not $m -or -not (Test-Path -LiteralPath $m.path)){ throw "Native model is unavailable: $name" }
  New-Item -ItemType Directory -Force $logDir | Out-Null
  $args=@('--model',$m.path,'--host','0.0.0.0','--port','1236','--alias',$name,'--n-gpu-layers','all','--split-mode','layer','--tensor-split','1,1','--ctx-size',[string]$m.ctx,'--parallel','1','--flash-attn','on','--cache-type-k','q8_0','--cache-type-v','q8_0','--batch-size','2048','--ubatch-size','512','--threads','16','--threads-batch','44')
  if($name -eq 'qwen3.8-27b-uncensored'){$args += @('--spec-type','draft-mtp','--spec-draft-n-max','2')}
  $p=Start-Process -FilePath $llama -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logDir 'server.log') -RedirectStandardError (Join-Path $logDir 'server.err.log') -PassThru
  return $p
}
function Wait-Native($p) {
  for($i=0;$i -lt 120;$i++) {
    if($p.HasExited){$detail=Get-Content -Raw (Join-Path $logDir 'server.err.log') -ErrorAction SilentlyContinue; throw "llama-server exited during startup: $detail"}
    try{$r=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:1236/v1/models' -TimeoutSec 5;if($r.StatusCode -eq 200){return}}catch{}
    Start-Sleep 1
  }
  throw 'llama-server did not become healthy within 120 seconds'
}
function Native-Healthy {
  try { $r=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:1236/v1/models' -TimeoutSec 3; return $r.StatusCode -eq 200 } catch { return $false }
}
function Switch-Native($current,[string]$name) {
  $current | Add-Member -NotePropertyName switching -NotePropertyValue $true -Force; Write-State $current
  if(Alive ([int]$current.pid)){ & taskkill.exe /PID ([int]$current.pid) /T /F | Out-Null; Start-Sleep 2 }
  $new=Launch-Native $name; Wait-Native $new
  $current.model=$name; $current.pid=$new.Id; $current.context=$models[$name].ctx; $current.requestedModel=$null; $current.switching=$false; Write-State $current
}

if($Action -eq 'Status'){ if($s=Read-State){$s | ConvertTo-Json -Depth 8}else{'inactive'}; exit 0 }
$s=Read-State
if($Action -eq 'Stop'){
  if($s -and $s.active){ if(Alive ([int]$s.pid)){ & taskkill.exe /PID ([int]$s.pid) /T /F | Out-Null }; Release-Leases $s; $s.active=$false; Write-State $s; Start-ScheduledTask -TaskName 'AlphaClash-ResumeTraining' }
  exit 0
}
if($Action -eq 'Switch'){
  if(-not $s -or -not $s.active){ throw 'Native host is not active' }
  if($s.model -eq $Model){ exit 0 }
  $s | Add-Member -NotePropertyName requestedModel -NotePropertyValue $Model -Force; Write-State $s; exit 0
}
if($s -and $s.active -and (Alive ([int]$s.pid))){ if($Hold){while((Read-State).active){Start-Sleep 10}}; exit 0 }

Stop-Training
try { & 'C:\Users\poopl\.lmstudio\bin\lms.exe' unload --all 2>$null | Out-Null } catch {}
$ids=@()
try {
  foreach($gpu in @(0,1)){
    $line=(& $python $lease acquire --vram 10000 --gpu $gpu --job llama-qwen-host --timeout 600 --max-hold 43200 --pid $PID 2>&1 | Where-Object {$_ -match '^\d+\s+\S+'} | Select-Object -First 1)
    if(-not $line){throw "GPU lease failed for GPU $gpu"}; $ids += (($line -split '\s+')[1])
  }
  $p=Launch-Native $Model; Wait-Native $p
  $s=[pscustomobject]@{active=$true;model=$Model;context=$models[$Model].ctx;pid=$p.Id;leaseIds=@($ids);startedAt=(Get-Date).ToString('o')}; Write-State $s
  Write-Output "READY $($ids -join ',') MODEL $Model"
  if($Hold){$deadSince=$null;while((Read-State).active){$current=Read-State;if(-not $current){Start-Sleep 1;continue};if($current.requestedModel -and $current.requestedModel -ne $current.model -and -not $current.switching){Switch-Native $current $current.requestedModel;$deadSince=$null;continue};if($current.switching){$deadSince=$null;Start-Sleep 1;continue};if(-not (Native-Healthy)){if(-not $deadSince){$deadSince=Get-Date}elseif(((Get-Date)-$deadSince).TotalSeconds -gt 180){throw 'llama-server health check failed for 180 seconds'}}else{$deadSince=$null};Start-Sleep 10}}
} catch {
  foreach($id in $ids){& $python $lease release $id | Out-Null}; if($s){$s.active=$false;Write-State $s}; Start-ScheduledTask -TaskName 'AlphaClash-ResumeTraining'; throw
}


