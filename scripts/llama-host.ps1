<#
Native llama.cpp host for the dual-3090 Qwen service.
The process owns two GPU leases while llama-server is alive. Switch changes
the model without dropping the leases; Stop releases both and resumes training.
#>
param(
    [Parameter(Mandatory=$true)][ValidateSet('Start','Switch','Stop','Status')]
    [string]$Action,
    [ValidateSet('qwen3.8-27b-uncensored','qwen3.8-27b-q4-1m','qwen3.8-flash-next-uncensored','qwen3.8-flash-next-uncensored-1m','authormist-originality','gemma4-12b-qat-uncensored-hauhaucs-balanced','gemma-4-31b','muse-glimmer-30b')]
    [string]$Model = 'qwen3.8-27b-uncensored',
    [int]$Parallel = 1,
    [int]$ContextOverride = 0,
    [int]$ReasoningBudget = -1,
    [switch]$SystemMemoryKV,
    [switch]$Hold,
    # -Hold stops the session after this many minutes with no requests; 0 = never.
    [int]$IdleMinutes = 60
)
. 'C:\AI-Server\scripts\as1-llm-policy.ps1'
if ($Action -in 'Start','Switch') { Assert-AS1LlmAllowed "llama-host $Action $Model" }
$ErrorActionPreference = 'Stop'
$root = 'C:\AI-Server'
$python = 'C:\Users\poopl\miniconda3\python.exe'
$lease = Join-Path $root 'scripts\gpulease.py'
$stateDir = Join-Path $root 'state\llama-host'
$statePath = Join-Path $stateDir 'state.json'
$logDir = Join-Path $root 'logs\llama-host'
$llama = 'C:\Users\poopl\.lmstudio\extensions\backends\llama.cpp-win-x86_64-nvidia-cuda12-avx2-2.39.0\llama-server.exe'
$mmproj = 'C:\Users\poopl\.lmstudio\models\orcarouter\Qwen3.8-27B-Uncensored-GGUF\mmproj-orcarouter_Qwen3.8-27B-Uncensored-f16.gguf'
# qwen4exp (Qwen3.8-Flash-Next) needs the unsloth fork: mainline and LM Studio's
# bundled build have no MTP graph for it and no cross-model tensor borrowing.
$llamaUnsloth = 'C:\AI-Server\tools\llama-unsloth-b11160\llama-server.exe'
# Inovello branch build (mainline + PR #27861 GPU-resident LRU expert cache +
# #28223 pinned host experts). Flash-Next uses this for --moe-expert-cache.
$llamaInovello = 'C:\AI-Server\tools\llama-inovello\build\bin\llama-server.exe'
$flashDir = 'C:\Users\poopl\.lmstudio\models\huihui-ai\Huihui-Qwen3.8-Flash-Next-abliterated-GGUF'

$models = @{
  'qwen3.8-27b-uncensored' = @{ path='C:\Users\poopl\.lmstudio\models\orcarouter\Qwen3.8-27B-Uncensored-GGUF\orcarouter_Qwen3.8-27B-Uncensored-Q6_K.gguf'; ctx=262144; sm='tensor' }
  # 2026-10-03: main 27B = orcarouter Q6_K (bartowski mirror), replacing JonathanColetti Q6_K (Tai: "delete the old uncensored one").
  # q4-1m = uncensored JonathanColetti Q4_K_M, outside LM Studio's models dir (see llama-child-host.ps1).
  'qwen3.8-27b-q4-1m' = @{ path='C:\AI-Server\models\gguf\JonathanColetti\Qwen3.8-27B-Uncensored-GGUF\Qwen3.8-27B-Uncensored-Q4_K_M.gguf'; ctx=1048576 }
  'authormist-originality' = @{ path='C:\Users\poopl\.lmstudio\models\mradermacher\authormist-originality-GGUF\authormist-originality.Q8_0.gguf'; ctx=32768 }
  'gemma4-12b-qat-uncensored-hauhaucs-balanced' = @{ path='C:\Users\poopl\.lmstudio\models\HauhauCS\Gemma4-12B-QAT-Uncensored-HauhauCS-Balanced\Gemma4-12B-QAT-Uncensored-HauhauCS-Balanced-Q4_K_M.gguf'; ctx=262144
    # Own projector: without it Launch-Native falls back to the 27B's $mmproj and llama-server
    # refuses to start (n_embd 3840 vs 5120). Found in the 2026-10-03 revert verification.
    mmproj='C:\Users\poopl\.lmstudio\models\HauhauCS\Gemma4-12B-QAT-Uncensored-HauhauCS-Balanced\mmproj-Gemma4-12B-QAT-Uncensored-HauhauCS-Balanced-BF16.gguf' }
  'gemma-4-31b' = @{ path='C:\Users\poopl\.lmstudio\models\lmstudio-community\gemma-4-31B-it-GGUF\gemma-4-31B-it-Q4_K_M.gguf'; ctx=262144 }
  'muse-glimmer-30b' = @{ path='C:\Users\poopl\.lmstudio\models\unsloth\Muse-Glimmer-30B-GGUF\Muse-Glimmer-30B-UD-Q4_K_XL.gguf'; ctx=131072 }
  # 125B total / 6B active MoE + 51B n-gram embedding table, 104 GB at UD-Q4_K_XL.
  # Tuned 2026-09-28 (see C:\AI-Server\out\bench\flash-next.jsonl):
  #  * GPU-resident LRU expert cache (--moe-expert-cache 160, Inovello build): ALL
  #    experts pinned in host RAM (=CUDA_Host), the hot ones cached in spare VRAM.
  #    This beats static -ot placement by ~1.6x. n-gram/PLE table pinned to CPU.
  #  * f16 KV (hybrid arch's KV is tiny), ubatch 512, MTP draft-n 3 on CUDA1.
  #  * 160 cache slots fill ~22.4/23.6 GB across both cards at 262k ctx.
  # Result: ~33 tok/s code, 30 prose, 33 thinking (vs 17/12/10 all-CPU on the old
  # unsloth build), 94% MTP acceptance on code. env LLAMA_ATTN_ROT_DISABLE=1.
  'qwen3.8-flash-next-uncensored' = @{
    path="$flashDir\UD-Q4_K_XL\Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf"; ctx=262144
    llama=$llamaInovello; mmproj="$flashDir\mmproj-model-bf16.gguf"; vram=23000
    draft='C:\Users\poopl\.lmstudio\models\unsloth\Qwen3.8-Flash-Next-GGUF\MTP\mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf'
    draftN=3; specDev='CUDA1'; kvType='f16'; batch=4096; ubatch=512; moeCache=160
    env=@{ LLAMA_ATTN_ROT_DISABLE='1' }
    extra=@('-ot','ffn_(gate|up|down)_exps\.weight=CUDA_Host,per_layer_token_embd\.weight=CPU')
  }
}
# Same weights at 1M tokens via YaRN x4 (the model card's supported extension).
# Only the 12 full-attention layers keep a growing KV cache (the DeltaNet linear
# layers carry a fixed-size recurrent state), but at 1M that KV still needs the
# VRAM the experts would use -- so ALL experts go to CPU here, GPUs hold the KV.
$models['qwen3.8-flash-next-uncensored-1m'] = $models['qwen3.8-flash-next-uncensored'].Clone()
$models['qwen3.8-flash-next-uncensored-1m'].ctx = 1048576
# At 1M the full-attention KV grows enough to compete with cache slots, so the
# cache is smaller here; YaRN x4 extends the 262k base to 1M.
$models['qwen3.8-flash-next-uncensored-1m'].moeCache = 60
$models['qwen3.8-flash-next-uncensored-1m'].extra = @('-ot','ffn_(gate|up|down)_exps\.weight=CUDA_Host,per_layer_token_embd\.weight=CPU',
  '--rope-scaling','yarn','--rope-scale','4','--yarn-orig-ctx','262144')
function Lease-Vram([string]$name) { if($models[$name].vram){[int]$models[$name].vram}else{10000} }

function Read-State { if (Test-Path -LiteralPath $statePath) { Get-Content -Raw $statePath | ConvertFrom-Json } }
function Write-State($v) { New-Item -ItemType Directory -Force $stateDir | Out-Null; $tmp=Join-Path $stateDir 'state.tmp'; $v | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $tmp; Move-Item -Force -LiteralPath $tmp -Destination $statePath }
function Alive([int]$processId) { try { $p=Get-Process -Id $processId -ErrorAction Stop; return -not $p.HasExited } catch { return $false } }
# One owner of the GPUs: while a native session runs, LM Studio's own server (:1234,
# JIT loading on) is stopped so nothing can load a second model onto the same cards;
# it comes back when the session ends. The :1235 proxy enforces the same rule.
# 2026-10-12: never (re)start LM Studio unless state\as1-llm.allowed (AS1 serves no LLM; this used to relaunch it on Stop).
function LmStudio-Server([string]$verb) { if ($verb -eq 'start' -and -not (Test-AS1LlmAllowed)) { return }; & cmd.exe /c ""C:\Users\poopl\.lmstudio\bin\lms.exe" server $verb >nul 2>&1" }
function Release-Leases($s) { foreach($id in @($s.leaseIds)) { & $python $lease release $id | Out-Null } }
function Stop-Training {
  @(Get-CimInstance Win32_Process | Where-Object {$_.CommandLine -and $_.CommandLine -match 'supervise-train\.ps1'}) | ForEach-Object { & taskkill.exe /PID ([int]$_.ProcessId) /T /F | Out-Null }
}
function Launch-Native([string]$name) {
  $m=$models[$name]; if(-not $m -or -not (Test-Path -LiteralPath $m.path)){ throw "Native model is unavailable: $name" }
  New-Item -ItemType Directory -Force $logDir | Out-Null
  if($Parallel -lt 1){ throw 'Parallel must be at least 1' }
  if($ContextOverride -lt 0){ throw 'ContextOverride must be zero or positive' }
  if($ReasoningBudget -lt -1){ throw 'ReasoningBudget must be -1 or nonnegative' }
  $ctx=if($ContextOverride -gt 0){$ContextOverride}else{$m.ctx}
  $isQ4OneM=($name -eq 'qwen3.8-27b-q4-1m')
  $flash='on'
  $batch=if($m.batch){[int]$m.batch}elseif($SystemMemoryKV){256}elseif($isQ4OneM){1024}else{2048}
  $ubatch=if($m.ubatch){[int]$m.ubatch}elseif($SystemMemoryKV){128}elseif($isQ4OneM){256}else{512}
  $kvType=if($m.kvType){$m.kvType}elseif($isQ4OneM){'q4_0'}else{'q8_0'}
  # Tensor split runs both cards on every layer instead of taking turns: +44% decode
  # on the 27B (C:\AI-Server\out\bench\bench27.jsonl, 2026-09-28). Other models keep layer.
  $sm=if($m.sm){$m.sm}else{'layer'}
  $exe=if($m.llama){$m.llama}else{$llama}
  if(-not (Test-Path -LiteralPath $exe)){ throw "llama-server binary is missing: $exe" }
  $args=@('--model',$m.path,'--host','0.0.0.0','--port','1236','--alias',$name,'--n-gpu-layers','all','--split-mode',$sm,'--tensor-split','1,1','--ctx-size',[string]$ctx,'--parallel',[string]$Parallel,'--flash-attn',$flash,'--cache-type-k',$kvType,'--cache-type-v',$kvType,'--batch-size',[string]$batch,'--ubatch-size',[string]$ubatch,'--threads','16','--threads-batch','44')
  if($m.moeCache){$args += @('--moe-expert-cache',[string]$m.moeCache)}
  if($SystemMemoryKV){$args += @('--no-kv-offload','--cache-ram','-1')}
  $proj=if($m.mmproj){$m.mmproj}else{$mmproj}
  if(Test-Path -LiteralPath $proj){$args += @('--mmproj',$proj,'--image-min-tokens','1024')}
  if($ctx -gt $m.ctx){$args += @('--rope-scaling','yarn','--rope-scale',[string]($ctx/$m.ctx),'--yarn-orig-ctx',[string]$m.ctx)}
  if($isQ4OneM -and $ctx -gt 262144){$args += @('--override-kv','qwen35.context_length=int:1048576')}
  if($Parallel -gt 1){$args += @('--kv-unified-per-slot',[string]([math]::Floor($ctx / $Parallel)))}
  if($ReasoningBudget -ge 0){$args += @('--reasoning-budget',[string]$ReasoningBudget)}
  if($name -eq 'qwen3.8-27b-uncensored'){$args += @('--spec-type','draft-mtp','--spec-draft-n-max','2')}
  # MTP head lives in a separate file; -md must be explicit or speculation is silently off.
  # It is a win at concurrency 1 only, so it is dropped for -Parallel > 1.
  if($m.draft -and $Parallel -eq 1 -and (Test-Path -LiteralPath $m.draft)){
    $args += @('-md',$m.draft,'--spec-type','draft-mtp','--spec-draft-n-max',[string]$m.draftN)
    if($m.specDev){$args += @('-devd',$m.specDev)}
  }
  if($m.extra){$args += $m.extra}
  if($m.env){ foreach($k in $m.env.Keys){ Set-Item -Path "Env:$k" -Value $m.env[$k] } }
  $outLog=Join-Path $logDir 'server.log'; $errLog=Join-Path $logDir 'server.err.log'
  # Some args (the -ot expert regex) contain | ( ) which Start-Process -ArgumentList
  # corrupts even when quoted. Launch through a .bat so the values pass verbatim,
  # then bind to the actual llama-server process (one runs at a time on :1236).
  $needsBat = ($args | Where-Object { $_ -match '[ |()]' }).Count -gt 0
  if($needsBat){
    Get-Process llama-server -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    $quoted = $args | ForEach-Object { if($_ -match '[ |()]'){ '"' + $_ + '"' } else { "$_" } }
    $bat=Join-Path $logDir 'launch.bat'
    "@echo off`r`n`"$exe`" $($quoted -join ' ') > `"$outLog`" 2> `"$errLog`"" | Set-Content -Encoding ascii $bat
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "`"$bat`"" -WindowStyle Hidden | Out-Null
    $srv=$null
    for($w=0;$w -lt 60 -and -not $srv;$w++){ Start-Sleep 1; $srv=Get-Process llama-server -EA SilentlyContinue | Select-Object -First 1 }
    if(-not $srv){ throw "llama-server did not appear after launch; see $errLog" }
    return $srv
  }
  $p=Start-Process -FilePath $exe -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru
  return $p
}
function Wait-Native($p) {
  for($i=0;$i -lt 600;$i++) {
    if($p.HasExited){$detail=Get-Content -Raw (Join-Path $logDir 'server.err.log') -ErrorAction SilentlyContinue; throw "llama-server exited during startup: $detail"}
    try{$r=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:1236/v1/models' -TimeoutSec 5;if($r.StatusCode -eq 200){return}}catch{}
    Start-Sleep 1
  }
  throw 'llama-server did not become healthy within 600 seconds'
}
function Native-Healthy {
  try { $r=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:1236/v1/models' -TimeoutSec 3; return $r.StatusCode -eq 200 } catch { return $false }
}
function Native-Activity {
  # id_task advances on every request; a changed value or a busy slot is activity.
  try { $slots=Invoke-RestMethod -Uri 'http://127.0.0.1:1236/slots' -TimeoutSec 3; return (@($slots | ForEach-Object { "$($_.id_task):$($_.is_processing)" }) -join ',') } catch { return $null }
}
function Stop-Session($s) {
  if(Alive ([int]$s.pid)){ & taskkill.exe /PID ([int]$s.pid) /T /F | Out-Null }; Release-Leases $s; $s.active=$false; Write-State $s; LmStudio-Server start; Start-ScheduledTask -TaskName 'AlphaClash-ResumeTraining' -ErrorAction SilentlyContinue
}
function Switch-Native($current,[string]$name) {
  $current | Add-Member -NotePropertyName switching -NotePropertyValue $true -Force; Write-State $current
  if(Alive ([int]$current.pid)){ & taskkill.exe /PID ([int]$current.pid) /T /F | Out-Null; Start-Sleep 2 }
  # Leases claim the peak of the model they cover; re-claim when that changes.
  if((Lease-Vram $name) -ne (Lease-Vram $current.model)){
    Release-Leases $current; $ids=@()
    foreach($gpu in @(0,1)){
      $savedEap=$ErrorActionPreference; $ErrorActionPreference='Continue'
      $line=(& $python $lease acquire --vram (Lease-Vram $name) --gpu $gpu --job llama-qwen-session --timeout 600 --max-hold 43200 2>$null | Where-Object {$_ -match '^\d+\s+\S+'} | Select-Object -First 1)
      $ErrorActionPreference=$savedEap
      if(-not $line){throw "GPU lease failed for GPU $gpu during switch"}; $ids += (($line -split '\s+')[1])
    }
    $current.leaseIds=@($ids); Write-State $current
  }
  $new=Launch-Native $name; Wait-Native $new
  $current.model=$name; $current.pid=$new.Id; $current.context=$models[$name].ctx; $current.requestedModel=$null; $current.switching=$false; Write-State $current
}

if($Action -eq 'Status'){ if($s=Read-State){$s | ConvertTo-Json -Depth 8}else{'inactive'}; exit 0 }
$s=Read-State
if($Action -eq 'Stop'){
  if($s -and $s.active){ Stop-Session $s }
  exit 0
}
if($Action -eq 'Switch'){
  if(-not $s -or -not $s.active){ throw 'Native host is not active' }
  if($s.model -eq $Model){ exit 0 }
  $s | Add-Member -NotePropertyName requestedModel -NotePropertyValue $Model -Force; Write-State $s; exit 0
}
if($s -and $s.active -and (Alive ([int]$s.pid))){ if($Hold){ Write-Output "READY existing MODEL $($s.model)"; while((Read-State).active){Start-Sleep 10} }; exit 0 }

Stop-Training
LmStudio-Server stop
try { & 'C:\Users\poopl\.lmstudio\bin\lms.exe' unload --all 2>$null | Out-Null } catch {}
$ids=@()
try {
  foreach($gpu in @(0,1)){
    # Session-owned lease: do not bind it to the transient SSH/PowerShell PID.
    # The host supervisor explicitly releases it on Stop; expiry is the crash
    # fallback. Binding to $PID lets gpulease reap a healthy llama process
    # when the SSH wrapper is replaced or detached.
    $savedEap=$ErrorActionPreference; $ErrorActionPreference='Continue'
    $line=(& $python $lease acquire --vram (Lease-Vram $Model) --gpu $gpu --job llama-qwen-session --timeout 600 --max-hold 43200 2>$null | Where-Object {$_ -match '^\d+\s+\S+'} | Select-Object -First 1)
    $ErrorActionPreference=$savedEap
    if(-not $line){throw "GPU lease failed for GPU $gpu"}; $ids += (($line -split '\s+')[1])
  }
  $p=Launch-Native $Model; Wait-Native $p
  $effectiveContext=if($ContextOverride -gt 0){$ContextOverride}else{$models[$Model].ctx}
  $s=[pscustomobject]@{active=$true;sessionOwned=$true;leaseScope='dsh-session';model=$Model;context=$effectiveContext;parallel=$Parallel;reasoningBudget=$ReasoningBudget;systemMemoryKV=[bool]$SystemMemoryKV;pid=$p.Id;leaseIds=@($ids);startedAt=(Get-Date).ToString('o')}; Write-State $s
  Write-Output "READY $($ids -join ',') MODEL $Model"
  if($Hold){
    # The launching SSH session can vanish without calling Stop (Windows keeps
    # this process alive), so the hold loop has to end the session itself when
    # nobody is using it -- otherwise the leases and 38 GB of VRAM live forever.
    $deadSince=$null;$lastActivity=Native-Activity;$idleSince=Get-Date
    while((Read-State).active){
      $current=Read-State;if(-not $current){Start-Sleep 1;continue}
      if($current.requestedModel -and $current.requestedModel -ne $current.model -and -not $current.switching){Switch-Native $current $current.requestedModel;$deadSince=$null;$idleSince=Get-Date;continue}
      if($current.switching){$deadSince=$null;$idleSince=Get-Date;Start-Sleep 1;continue}
      if(-not (Native-Healthy)){if(-not $deadSince){$deadSince=Get-Date}elseif(((Get-Date)-$deadSince).TotalSeconds -gt 180){throw 'llama-server health check failed for 180 seconds'}}else{$deadSince=$null}
      $activity=Native-Activity
      if($null -eq $activity -or $activity -ne $lastActivity -or $activity -match ':True'){$lastActivity=$activity;$idleSince=Get-Date}
      elseif($IdleMinutes -gt 0 -and ((Get-Date)-$idleSince).TotalMinutes -ge $IdleMinutes){Write-Output "IDLE ${IdleMinutes}m -- stopping session";Stop-Session $current;break}
      Start-Sleep 10
    }
  }
} catch {
  foreach($id in $ids){& $python $lease release $id | Out-Null}; if($s){$s.active=$false;Write-State $s}; LmStudio-Server start; Start-ScheduledTask -TaskName 'AlphaClash-ResumeTraining' -ErrorAction SilentlyContinue; throw
}



