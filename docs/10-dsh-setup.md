# DeepSeek Harness setup

> **Main entry: `flash-next` (2026-10-10).** On the Mac DSH install (`~/Documents/deepseek-harness`) the default
> model is `flash-next`, served by the Mac proxy `dsh-mac-proxy.mjs` on `127.0.0.1:1235`. It goes to **AI Server 2's
> Flash-Next** (Strix Halo, gufo, 262k, MTP) when that LLM is on, and otherwise to **AI Server 1's**
> `qwen3.8-flash-next-uncensored` (the fallback, and the current default while AI Server 2's LLM is off). See
> [Mac client: AI Server 2 main entry](#mac-client-ai-server-2-main-entry) below and [docs/17](17-ai-server-2-llm.md).

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

### Required portability edits

The checked-in files are configured for the original client and are not a
drop-in installer. Before running them on another client, make these edits:

| File | Replace | With |
|---|---|---|
| `dsh-agentic.ps1` | `C:\Users\Tai\.dsh` | `C:\Users\<user>\.dsh` |
| `dsh-agentic.ps1` | `poopl@100.71.113.77` | `<ssh-user>@<ai-server>` |
| `dsh-agentic.ps1` | `100.71.113.77` in the wake/health values | the AI server's Tailscale address |
| `dsh-model-proxy.mjs` | `http://100.71.113.77:1236` | `http://<ai-server>:1236` |
| `dsh-child-proxy.mjs` | `http://100.71.113.77:1236` | `http://<ai-server>:1236` |

The launcher file also contains the original user's global npm path. Replace
its contents with this portable version so it works for any Windows account:

```javascript
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const entry = path.join(process.env.APPDATA, 'npm', 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js');
const { runCli } = await import(pathToFileURL(entry).href);
await runCli();
```

Use `Select-String` to find values that still belong to the original machine:

```powershell
Select-String -Path "$env:USERPROFILE\.dsh\*.ps1","$env:USERPROFILE\.dsh\*.mjs" -Pattern 'Tai|100\.71\.113\.77|poopl@'
```

Every result should be intentional before continuing.

### Copy the client configuration safely

Copy code and configuration files only. Do not copy these files or directories
from the original client:

```text
.credentials.yaml
sessions\
storages\
attachments\
*.log
```

After installing the DSH package, create a fresh `settings.yaml` with the
local proxy endpoints. The important values are:

```yaml
agent-default-model:
  provider: tai-ai-server
  model: qwen3.8-27b-uncensored

llm-pi-ai:
  providers:
    tai-ai-server:
      api: openai-completions
      baseURL: http://127.0.0.1:1235/v1
      models:
        - id: qwen3.8-27b-uncensored
        - id: qwen3.8-flash-next-uncensored
        - id: qwen3.8-flash-next-uncensored-1m
    tai-ai-server-child:
      api: openai-completions
      baseURL: http://127.0.0.1:1238/v1
      models:
        - id: qwen3.8-27b-child
```

Model registration is **per-machine**: `cordis.patch.yml` is auto-loaded from
`$DSH_HOME` (the harness's `home/`) as the user layer. A model added on one
workstation does not appear on another — add the same `- id:` lines to each
client's `cordis.patch.yml`. Verify with
`dsh --profile headless --dump-config | grep flash-next`. See
[`13-qwen3.8-flash-next.md`](13-qwen3.8-flash-next.md) for that model.

Do not set the DSH provider URL to the server's `1236` address. Port `1236`
is the unauthenticated native service; the client must use the local `1235`
and `1238` proxies.

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

For the current installation, those values are:

```powershell
$server = 'poopl@100.71.113.77'
$wakeRelay = '100.127.179.9'
$wakeUrl = 'https://wake-relay.tail215694.ts.net/wake'
$remote = 'C:\AI-Server\scripts\llama-host.ps1'
```

The new client still uses these same server values if it is connecting to this
AI server; only the client-local `C:\Users\<user>\.dsh` paths change.

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

### First connection walkthrough

Run these steps on the **client**, not on the AI server:

1. Open PowerShell and confirm the client can reach the server:

   ```powershell
   tailscale ping <ai-server>
   ssh <ssh-user>@<ai-server> powershell.exe -NoProfile -Command "Write-Output SSH_OK"
   ```

2. Confirm the client-side DSH configuration points at local ports:

   ```powershell
   Select-String -Path "$env:USERPROFILE\.dsh\settings.yaml" -Pattern 'baseURL'
   ```

   It must show `http://127.0.0.1:1235/v1` and, for children,
   `http://127.0.0.1:1238/v1`.

3. Start the managed connection:

   ```powershell
   dsh -l
   ```

   The wrapper wakes the server, opens the SSH-held `llama-host.ps1` session,
   waits for the `READY` message, starts ports 1235 and 1238, and then starts
   the DSH web server on port 3080.

4. Open the complete URL printed by DSH. It includes an authentication token;
   opening only `http://127.0.0.1:3080/` returns `401`.

5. In a second PowerShell window, verify the connection:

   ```powershell
   Get-NetTCPConnection -State Listen -LocalPort 3080,1235,1238
   Invoke-RestMethod http://127.0.0.1:1235/v1/models
   ssh <ssh-user>@<ai-server> powershell.exe -NoProfile -Command "Invoke-RestMethod http://127.0.0.1:1236/v1/models"
   ```

   The first command should show three local listeners, and both model queries
   should return a JSON model list.

The connection is therefore local from DSH's perspective: DSH talks to
`127.0.0.1`, while the managed proxy talks to the AI server. You do not paste
the remote server URL into the DSH UI.

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

## Mac client: AI Server 2 main entry

Added 2026-10-10. The Windows workstation client described above (`C:\Users\Tai\.dsh`, node `tpc`) was not
reachable for this change: no ssh or other open port on the tailnet. It still uses the AI Server 1-only proxy. The Mac
DSH install now has its own proxy.

| | |
|---|---|
| Proxy | `~/Documents/deepseek-harness/bin/dsh-mac-proxy.mjs` (source: [`scripts/dsh-mac-proxy.mjs`](../scripts/dsh-mac-proxy.mjs)), Node 22, no dependencies |
| Service | LaunchAgent `~/Library/LaunchAgents/com.tai.dsh-mac-proxy.plist` (`RunAtLoad`, `KeepAlive`); log `~/Library/Logs/dsh-mac-proxy.log` |
| Listens | `127.0.0.1:1235` (Mac only, no auth). DSH provider `tai-ai-server` -> `http://127.0.0.1:1235/v1` |
| DSH config | `home/cordis.patch.yml`: models `flash-next` (default), `qwen3.8-flash-next-uncensored-strix`, then AI Server 1's ids. Backup `cordis.patch.yml.bak-20261010` |
| Keys (never in a repo) | `~/.config/ai-server-2/llm_api_key` (AI Server 2, same as `/etc/ai-server-2/llm.env`) and `~/.config/ai-server/model_proxy_api_key` (a dedicated line in AI Server 1's `C:\AI-Server\scripts\.api-key`; backup `.api-key.bak-20261010-macdsh`; delete that line to revoke) |

Routing:

| model id | goes to |
|---|---|
| `flash-next` (default) | AI Server 2 `http://100.65.60.112:8080` if its `/health` answers; otherwise AI Server 1 `http://100.71.113.77:1235` as `qwen3.8-flash-next-uncensored`. If AI Server 2 is asleep and its LLM was serving within the last 2 days, it also starts `wake-ai-server-2` in the background for next time |
| `qwen3.8-flash-next-uncensored-strix` | AI Server 2 only (on demand): wakes the box if needed, waits up to 2 min for the model; when the LLM is off it returns 503 "AI Server 2 LLM is off. Turn it on: ssh ai-server-2 sudo systemctl enable --now llm.target" |
| anything else | AI Server 1's model proxy, which starts/switches its native host and takes its GPU leases itself. If AI Server 1 does not answer, the proxy calls the wake relay (`https://wake-relay.tail215694.ts.net/wake`) and waits up to 5 min |

AI Server 2 needs **no GPU lease** (one GPU, one model). Keep-awake: for 30 min after the last request to AI Server 2
the proxy polls its `/health` every 5 min. AI Server 2's power daemon counts any `:8080` connection in the last
15 min as LLM activity ([docs/16](16-ai-server-2-wake-and-power.md)), so the box stays up while DSH uses it. Waking
is slow today: Wi-Fi wake does not work, so a sleeping box answers on its RTC heartbeat (<= 20 min).

Verified 2026-10-10 from the Mac:

- `GET 127.0.0.1:1235/v1/models` lists `flash-next`, `qwen3.8-flash-next-uncensored-strix` and AI Server 1's models.
- The `-strix` route with the LLM off returns the 503 above.
- Directly against AI Server 2 while it was serving: models, chat, uncensored check, and streaming (SSE chunks) all
  worked over the tailnet.
- `flash-next` -> AI Server 1 fallback reached AI Server 1's proxy (auth OK). The request then **timed out after
  5 min**: AI Server 1's native Flash-Next host needs both 3090s, and GPU 1 was held by the `clashlearner` lease
  (the attacker PPO learner). While AI Server 1 is training, its Flash-Next cannot load. Use AI Server 2
  (`enable --now llm.target`, with the battle jobs stopped), or wait for the learner to finish.
- Not yet run end to end through the proxy with AI Server 2 on: it was switched off before the proxy existed.
  First time it is on, check:
  `curl -s localhost:1235/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"flash-next","messages":[{"role":"user","content":"hi"}],"stream":true}'`
  and look for `-> ais2` in the log.

```bash
launchctl kickstart -k gui/$(id -u)/com.tai.dsh-mac-proxy    # restart after editing the .mjs
tail -f ~/Library/Logs/dsh-mac-proxy.log
curl -s localhost:1235/health                                # {"status":"ok","ais2_llm":true|false}
```

To give the Windows client the same main entry, add the same three routes to its `dsh-model-proxy.mjs`:
`flash-next` -> AI Server 2 :8080 with the bearer key (stored in that client's DSH credential store), falling back to
the existing native route. Do not take GPU leases for AI Server 2.
