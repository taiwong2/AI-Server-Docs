@echo off
rem dsh.cmd: Windows port of the Mac bin/dsh wrapper (DeepSeek Harness client). Works from cmd and PowerShell.
rem  - DSH_HOME = %USERPROFILE%\deepseek-harness\home, DSH_PERMISSION_MODE defaults to workspace-write
rem  - `--profile headless` is the default when arguments are given (except --help/-h/--version/-V/web/plugin/--profile)
rem  - typed in a terminal (stdin and stdout a console) and DSH_NO_LLM_MODE unset: turn on AI Server 2's LLM mode first
rem    (bin\dsh-llm-mode.ps1 on), keep it alive with a touch every 5 min while dsh runs, one final touch at exit.
rem    Scripts/agents (redirected I/O) and DSH_NO_LLM_MODE=1 skip that; the proxy on 127.0.0.1:1235 still routes
rem    flash-next to AI Server 2 when it is up, else AI Server 1.
setlocal
set "DSH_ROOT=%USERPROFILE%\deepseek-harness"
set "DSH_HOME=%DSH_ROOT%\home"
if not defined DSH_PERMISSION_MODE set "DSH_PERMISSION_MODE=workspace-write"
set "DSH_JS=%DSH_ROOT%\node_modules\@deepseek-ai\dsh\lib\bin.js"
set "HOOK=%DSH_ROOT%\bin\dsh-llm-mode.ps1"
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

set "PROFILE_ARGS="
set "KEEPF="
set "A1=%~1"
if "%A1%"=="" goto session
for %%x in (--help -h --version -V web plugin) do if "%A1%"=="%%x" goto direct
if "%A1%"=="--profile" goto session
set "PROFILE_ARGS=--profile headless"

:session
if defined DSH_NO_LLM_MODE goto run
if not exist "%HOOK%" goto run
set "KEEPF=%TEMP%\dsh-keepalive-%RANDOM%%RANDOM%.flag"
"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%HOOK%" session "%KEEPF%"
if errorlevel 1 set "KEEPF="
:run
node "%DSH_JS%" %PROFILE_ARGS% %*
set "RC=%errorlevel%"
if defined KEEPF if exist "%KEEPF%" del /q "%KEEPF%" >nul 2>&1
exit /b %RC%

:direct
node "%DSH_JS%" %*
exit /b %errorlevel%
