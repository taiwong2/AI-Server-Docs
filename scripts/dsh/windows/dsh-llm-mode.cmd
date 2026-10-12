@echo off
rem dsh-llm-mode on|touch|status|off  (see dsh-llm-mode.ps1)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%USERPROFILE%\deepseek-harness\bin\dsh-llm-mode.ps1" %*
exit /b %errorlevel%
