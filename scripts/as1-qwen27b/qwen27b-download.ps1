$ErrorActionPreference='Continue'
# 2026-11-13: bartowski's ungated mirror of orcarouter/Qwen3.8-27B-Uncensored (abliterated), the same weights as AS1's
# pre-10-12 qwen3.8-27b-uncensored (file orcarouter_Qwen3.8-27B-Uncensored-Q6_K.gguf); Q4_K_M for disk room.
$dir='C:\AI-Server\models\gguf\orcarouter\Qwen3.8-27B-Uncensored-GGUF'
New-Item -ItemType Directory -Force $dir | Out-Null
$log='C:\AI-Server\logs\qwen27b-download.log'
"start $(Get-Date -Format s) bartowski/orcarouter" | Out-File -Append $log
& 'C:\Users\poopl\AppData\Local\Programs\Python\Python312\Scripts\hf.exe' download bartowski/orcarouter_Qwen3.8-27B-Uncensored-GGUF orcarouter_Qwen3.8-27B-Uncensored-Q4_K_M.gguf mmproj-orcarouter_Qwen3.8-27B-Uncensored-f16.gguf --local-dir $dir *>> $log
"exit $LASTEXITCODE $(Get-Date -Format s)" | Out-File -Append $log
