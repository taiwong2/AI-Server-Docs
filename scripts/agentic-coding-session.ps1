<#
  GPU handoff for the local DeepSeek Harness.
  Acquire stops the known AlphaClash training supervisors, takes one lease per
  GPU for LM Studio/Qwen, and holds those leases while the caller stays alive.
  Release unloads Qwen and starts the existing server-side resume task.
#>
param(
    [Parameter(Mandatory=$true)][ValidateSet('Acquire','Release','Status')]
    [string] $Action,
    [int] $Vram = 22000,
    [switch] $Hold
)

$ErrorActionPreference = 'Stop'
$root = 'C:\AI-Server'
$python = 'C:\Users\poopl\miniconda3\python.exe'
$lease = Join-Path $root 'scripts\gpulease.py'
$lms = 'C:\Users\poopl\.lmstudio\bin\lms.exe'
$stateDir = Join-Path $root 'state\agentic-coding'
$statePath = Join-Path $stateDir 'handoff.json'
$qwen = 'qwen3.8-27b-uncensored'

function Read-State {
    if (Test-Path -LiteralPath $statePath) { return Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json }
    return $null
}

function Write-State($value) {
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    $value | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $statePath
}

function Stop-Training {
    $items = @(Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -and $_.CommandLine -match 'supervise-train\.ps1'
    })
    $saved = @()
    foreach ($item in $items) {
        $saved += [pscustomobject]@{
            Run = if ($item.CommandLine -match '-Run\s+([^\s]+)') { $Matches[1] } else { $null }
            Vram = if ($item.CommandLine -match '-Vram\s+(\d+)') { [int]$Matches[1] } else { 22000 }
            CommandLine = $item.CommandLine
        }
        & taskkill.exe /PID ([int]$item.ProcessId) /T /F | Out-Null
    }
    return $saved
}

if ($Action -eq 'Status') {
    if (Test-Path -LiteralPath $statePath) { Get-Content -Raw -LiteralPath $statePath } else { 'inactive' }
    exit 0
}

if ($Action -eq 'Acquire') {
    $old = Read-State
    if ($old -and $old.active) {
        $oldLeasePath = Join-Path (Join-Path $root 'state\gpu-leases') "$($old.leaseId).json"
        if (Test-Path -LiteralPath $oldLeasePath) {
            Write-Output "READY $($old.leaseId)"
            if ($Hold) { while ((Read-State).active) { Start-Sleep -Seconds 10 } }
            exit 0
        }
        $old.active = $false
        Write-State $old
    }

    # Free any model left resident by a previous session before asking
    # gpulease for memory; otherwise the lease can wait behind its own model.
    try { & $lms unload --all 2>$null | Out-Null } catch { }
    $saved = @()
    # ResumeTraining may be starting a supervisor at the same time as this
    # acquire. Re-scan during a settling window so no trainer can race the
    # agentic lease back onto a card after we thought the GPUs were clear.
    for ($pass = 0; $pass -lt 5; $pass++) {
        $saved += Stop-Training
        Start-Sleep -Seconds 2
        & $python $lease reap | Out-Null
    }
    # Qwen is a dual-GPU load. Reserve both cards transactionally so another
    # job cannot start on the unaccounted card while LM Studio is loading.
    $leaseIds = @()
    try {
        foreach ($gpu in @(0, 1)) {
            $line = (& $python $lease acquire --vram $Vram --gpu $gpu --job dsh-agentic-coding --timeout 600 --max-hold 43200 --pid $PID 2>&1 | Where-Object { $_ -match '^\d+\s+\S+' } | Select-Object -First 1)
            if (-not $line) { throw "GPU lease was not granted for GPU $gpu" }
            $parts = "$line".Trim() -split '\s+'
            $leaseIds += $parts[1]
        }
    } catch {
        foreach ($leaseId in $leaseIds) { & $python $lease release $leaseId | Out-Null }
        Start-ScheduledTask -TaskName 'AlphaClash-ResumeTraining'
        throw
    }
    $record = [pscustomobject]@{ active = $true; leaseIds = @($leaseIds); leaseId = $leaseIds[0]; gpu = '0,1'; vram = $Vram; savedTraining = @($saved); startedAt = (Get-Date).ToString('o') }
    Write-State $record
    try {
        # Use every available GPU allocation across the visible GPUs. LM
        # Studio enables Flash Attention, GPU KV cache, and MTP for this GGUF.
        $previousErrorAction = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $loadOutput = (& $lms load $qwen --gpu max --context-length 262144 --parallel 1 --identifier $qwen -y 2>&1 | Out-String)
        $loadExitCode = $LASTEXITCODE
        $ErrorActionPreference = $previousErrorAction
        if ($loadExitCode -ne 0) { throw "LM Studio load failed: $loadOutput" }
        Write-Output "READY $($record.leaseId) GPU $($record.gpu)"
        if ($Hold) { while ((Read-State).active) { Start-Sleep -Seconds 10 } }
        exit 0
    } catch {
        try { & $python $lease release $record.leaseId | Out-Null } catch { }
        $record.active = $false
        Write-State $record
        throw
    }
}

$state = Read-State
if (-not $state -or -not $state.active) { Write-Output 'already inactive'; exit 0 }
try { & $lms unload $qwen 2>$null | Out-Null } catch { }
$releaseIds = if ($state.leaseIds) { @($state.leaseIds) } else { @($state.leaseId) }
foreach ($leaseId in $releaseIds) { & $python $lease release $leaseId | Out-Null }
$state.active = $false
$state | Add-Member -NotePropertyName releasedAt -NotePropertyValue ((Get-Date).ToString('o')) -Force
Write-State $state
Start-ScheduledTask -TaskName 'AlphaClash-ResumeTraining'
Write-Output 'RELEASED; AlphaClash-ResumeTraining triggered'
