# DeepSeek Harness setup

This guide reproduces the working native llama.cpp setup for the DeepSeek
Harness (`dsh`) on a new Windows client talking to a separate Windows AI
server. It deliberately keeps credentials, API keys, and machine-specific
paths out of the repository.

There are two machines in this setup:

| Machine | Role |
|---|---|
| Client | Runs DSH, the local proxies, and the browser UI |
| AI server | Owns the GPUs and runs the native llama.cpp service |

## Architecture

1. `dsh-agentic.ps1` wakes the AI server, starts the native host over SSH, and
   keeps the session alive.
2. `dsh-model-proxy.mjs` listens on `127.0.0.1:1235`, exposes the installed
   model catalog, serializes model switches, and forwards OpenAI-compatible
   requests to llama.cpp.
3. `llama-host.ps1` owns both GPU leases and runs llama.cpp on port `1236`.

The proxy is the client endpoint; the native service is not exposed publicly.

## How the client connects to the local AI

The normal request path is:

```text
Browser / DSH
    -> http://127.0.0.1:3080       authenticated DSH web UI
    -> http://127.0.0.1:1235/v1    local model proxy
    -> http://<ai-server>:1236     native llama.cpp over the trusted network
```

The client proxy does not require the browser to know the AI server's model
endpoint. `dsh-agentic.ps1` wakes the server when needed, opens the SSH-held
server session, starts the local proxies, and keeps the GPU lease alive. The
client's DSH settings therefore point to `127.0.0.1:1235`, not directly to
port `1236`:

```yaml
baseURL: http://127.0.0.1:1235/v1
```

For a direct connectivity test from the client:

```powershell
tailscale ping <ai-server>
Test-NetConnection <ai-server> -Port 1236
Invoke-RestMethod http://127.0.0.1:1235/v1/models
```

For a server-side test, bypass the client proxy and query llama.cpp locally:

```powershell
ssh <ssh-user>@<ai-server> powershell.exe -NoProfile -Command "Invoke-RestMethod http://127.0.0.1:1236/v1/models"
```

If the server-side test works but the client proxy test fails, inspect the
client wrapper/proxy logs. If the local proxy responds with `503` and
`model_proxy_error`/`fetch failed`, the remote llama.cpp service is down or
unreachable; check the server's `llama-host.ps1 -Action Status` output.

## 1. Prepare the client

The client needs Windows PowerShell 5.1 or newer, Node.js 22.19 or newer,
OpenSSH, and Tailscale. Install DSH globally:

```powershell
npm install -g @deepseek-ai/dsh
```

Confirm the tools are available:

```powershell
node --version
ssh -V
tailscale version
dsh --help
```

Create the client directory and copy these files from this handbook's machine
or from a versioned deployment bundle:

```text
C:\Users\<user>\.dsh\dsh-agentic.ps1
C:\Users\<user>\.dsh\dsh-launcher.mjs
C:\Users\<user>\.dsh\dsh-model-proxy.mjs
C:\Users\<user>\.dsh\dsh-child-proxy.mjs
C:\Users\<user>\.dsh\settings.yaml
```

The launcher wrapper must also be on `PATH`, for example:

```text
C:\Users\<user>\bin\dsh.cmd
```

Use this content, changing only the user path:

```bat
@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Users\<user>\.dsh\dsh-agentic.ps1" %*
exit /b %errorlevel%
```

If the client uses a different account or install location, update every
hard-coded client path in `dsh-agentic.ps1` and the wrapper. Do not copy the
original user's credential files or session storage.

## 2. Configure client-to-server access

Install and sign in to Tailscale on both machines. Give the AI server a stable
Tailscale address or DNS name. Set the values near the top of
`dsh-agentic.ps1`:

```powershell
$server = '<ssh-user>@<ai-server-tailscale-name-or-ip>'
$wakeRelay = '<wake-relay-tailscale-name-or-ip>'
$wakeUrl = 'https://<wake-relay-host>/wake'
$remote = 'C:\AI-Server\scripts\llama-host.ps1'
```

Configure SSH key authentication from the client to the AI server. Verify it
before starting DSH:

```powershell
tailscale ping <ai-server>
ssh <ssh-user>@<ai-server> powershell.exe -NoProfile -Command "Write-Output ready"
```

The AI server's SSH account must be able to start the native host script and
run its GPU lease helper without an interactive password prompt. Never publish
port `1236` to the public internet: llama.cpp has no API key in this setup.

## 3. Prepare the AI server

Install these files on the AI server:

```text
C:\AI-Server\scripts\gpulease.py
C:\AI-Server\scripts\llama-host.ps1
```

The native host uses the bundled CUDA llama.cpp runtime and Qwen Q6 GGUF with:

```text
Qwen Q6_K, 1048576 context, one slot, both RTX 3090s, system-memory KV, layer split 1,1
Flash Attention, q8 K/V cache, batch 2048, ubatch 512
16 generation threads, 44 batch threads, parallelism 1, draft-MTP2, Qwen thinking disabled
```

The reproducible host script is [scripts/llama-host.ps1](../scripts/llama-host.ps1).
Deploy it as `C:\AI-Server\scripts\llama-host.ps1` on another server. Edit the
script's `$python`, `$lease`, `$llama`, `$root`, and model-map paths for the
target account and installed model files. Install `gpulease.py` beside it at
`C:\AI-Server\scripts\gpulease.py`.

Before using DSH, test the server host directly:

```powershell
ssh <ssh-user>@<ai-server> powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\AI-Server\scripts\llama-host.ps1 -Action Start -Model qwen3.8-27b-uncensored -Hold
ssh <ssh-user>@<ai-server> powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\AI-Server\scripts\llama-host.ps1 -Action Status
ssh <ssh-user>@<ai-server> powershell.exe -NoProfile -Command "(Invoke-WebRequest http://127.0.0.1:1236/v1/models).StatusCode"
ssh <ssh-user>@<ai-server> powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\AI-Server\scripts\llama-host.ps1 -Action Stop
```

Keep the first SSH window open because `-Hold` supervises the native process.
From a second window, `Status` should show `active: true` and the localhost
probe should return HTTP 200. Stop the test host afterward; the DSH wrapper
will own the leases during normal use.

The measured warm benchmark was 48.32 tok/s direct and 47.19 tok/s through the
DSH proxy at 256 generated tokens. Native model switching is serialized by the
host supervisor; Authormist switched and answered in 13.77 seconds.

The handoff acquires one lease per GPU, releases both transactionally, and
resumes AlphaClash only after the native server is stopped. Dead-owner,
reused-PID, failed-load, failed-switch, idle, and crash recovery paths are
covered by the lease broker and host supervisor.

## 4. Wake and run

The wrapper calls the tailnet-only wake relay before SSH:

```text
https://wake-relay.tail215694.ts.net/wake
```

Then run:

```powershell
dsh -l
```

Open the authenticated URL printed by DSH. A bare
`http://127.0.0.1:3080/` returns `401` by design; use the URL containing the
token.

On the first run, allow the browser to open and keep the terminal process
alive. The wrapper holds the server-side GPU lease for the lifetime of the DSH
session. To stop it, close DSH normally or press `Ctrl+C`; do not kill only
llama.cpp while leaving the wrapper alive.

## 5. Verify

```powershell
tailscale ping 100.71.113.77
ssh poopl@100.71.113.77 "curl.exe -s http://127.0.0.1:1236/v1/models"
Get-Content "$env:USERPROFILE\.dsh\dsh-agentic-wrapper.log" -Tail 20
Get-Content "$env:USERPROFILE\.dsh\dsh-model-proxy.log" -Tail 20
```

Use `http://127.0.0.1:1235/v1` for client requests so model switching is
exercised. Do not expose port 1236 publicly; it has no API key in this setup.

The current wrapper treats a listening DSH process as reusable only when both
local proxies and the server's port `1236` are reachable. If a previous
session died halfway through startup, `dsh -l` cleans up the stale launcher
and retries instead of returning a false “already running” message.

## 6. Machine-specific checklist

Before calling a new machine complete, verify:

- `ssh` works without a password prompt from the client.
- The server model paths in `llama-host.ps1` exist.
- `gpulease.py list` works under the SSH account.
- The server can bind `0.0.0.0:1236`, but its firewall does not expose that
  port outside the trusted network/tailnet.
- `dsh -l` prints a tokenized URL and `http://127.0.0.1:1235/v1/models`
  responds locally.
- A small prompt succeeds before testing a 256K-context request.
- The server reports inactive after DSH is stopped and both GPU leases are
  released.

Do not copy `.credentials.yaml`, cookies, session JSON, or API keys from the
original machine. Create fresh credentials and SSH keys on the new client.

## Subagents and multi-agent work

The installed DSH `standard` preset already enables `subagent` for one-shot or
continuable child agents, `subagent_fork` for same-route forked work,
`list_agents` and child control/messaging, plus the `workflow` engine. Workflow
helpers support fan-out with `parallel()` and ordered stages with `pipeline()`.
Child model/provider selection is enabled by the preset, so a child can use a
different model from the catalog when the task benefits from it.

This is supported, but the native host is tuned for one 1M main-agent request
(`--parallel 1`). Multiple agents can overlap file and tool work; their model
turns queue behind the single llama.cpp inference slot. DSH child options can
select a model and cap output tokens, but cannot set a different child
`contextWindow`. Logical children use fresh DSH contexts and queue behind the
single native inference slot. A second native child process is not supported on
this GPU host.

For multi-GPU tuning background, see the [llama.cpp multi-GPU guide](https://github.com/ggml-org/llama.cpp/blob/master/docs/multi-gpu.md)
and [dual-3090 Qwen reports](https://www.reddit.com/r/LocalLLM/comments/1voyohk/qwen3827b_single_vs_multigpu_benchmarks/).
