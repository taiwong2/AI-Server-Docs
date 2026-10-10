# Troubleshooting

## DeepSeek Harness browser and credential failures (2026-09-14)

If DSH web shows `401 Unauthorized`, do not open `http://127.0.0.1:8787/`
directly. DSH prints an authenticated URL containing a one-time `token`; open
that exact URL once so it can mint the browser cookie, then the clean root URL
works. A stale token or a server restart requires the newly printed URL.

If a request reports `MISSING_CREDENTIAL` for `tai-ai-server`, confirm the
Models page says **API key configured** and that the DSH credential store has a
non-empty `AI_SERVER_API_KEY` reference. A user environment variable exported
after DSH started is not visible to that running process; restart DSH or store
the reference through the credential service. LM Studio does not require real
authentication, but the OpenAI-compatible adapter still requires a placeholder
credential or Authorization header.

On Windows Node 22.15, the installed DSH launcher did not invoke its CLI entry
point correctly. The working wrapper is `C:\Users\Tai\.dsh\dsh-launcher.mjs`;
upgrade Node to the package's supported 22.19+ line before removing the wrapper.

Symptoms first, with the answers that were expensive to find.

## Native llama.cpp says the model is unavailable

DSH must use `http://127.0.0.1:1235/v1`; the proxy asks the long-lived native
host to switch models and waits for `/v1/models` to become healthy. Check
`dsh-model-proxy.log`, `C:\AI-Server\logs\llama-host\server.err.log`, and
`C:\AI-Server\state\llama-host\state.json`. The tested Q6/256K Qwen profile
uses both GPUs, layer split `1,1`, Flash Attention, q8 K/V cache, MTP2, batch
2048, and ubatch 512; it measured 48.32 tok/s direct and 47.19 tok/s through
the proxy. The handoff reaps dead/reused-PID leases and cleans up failed loads.

## "The server is down"

It is almost certainly asleep. `ping 192.168.1.24`; if nothing answers, wake it
([Wake and power](05-wake-and-power.md)). Only after a wake attempt and ~20
minutes (one heartbeat) should you suspect a real fault.

## The box never sleeps

Run `python C:\AI-Server\scripts\jobqueue.py status` — it names the gate that is
holding it awake. Usual answers:

- **`a server is listening on 25565`** — the Minecraft server. Correct
  behaviour; remove the port from `busy_ports` if the server has retired.
- **`console input Ns ago`** — somebody is at the keyboard, or
  `AI-InputHeartbeat` is reporting a stale reading.
- **`N GPU lease(s)`** — a job is holding a card. `gpulease.py list`, then
  `reap` if the owner is gone.
- **`NOT sleeping: could not arm the heartbeat wake`** — the runner is not
  elevated. Re-run `install-jobqueue.ps1` as Administrator.

## The box slept and did not come back

Wake it from the LAN (`wake-pc.sh`) or via the relay. If neither works, the
firmware is not honouring the wake — check the **ErP / deep-sleep setting in the
MSI BIOS**. The queue's fail-closed rule means this should not happen: it
refuses to sleep without an armed wake.

## A scheduled task "does not exist" but clearly runs

`Get-ScheduledTask` and `Win32_Process` hide SYSTEM tasks and their command
lines from unelevated callers. The task is fine; your query is blind. Ask
through an elevated shell.

## A job works by hand and fails instantly in the queue

Path resolution. The runner is SYSTEM; `$env:USERPROFILE` is
`C:\WINDOWS\system32\config\systemprofile`, not `C:\Users\poopl`. Read the job
log — the handlers print every location they looked in.

Both known cases: the conda `ai` interpreter, and the per-user `claude.exe`
plus its credentials.

## A config edit has no effect

Check for a **byte-order mark**. PowerShell's `Out-File -Encoding utf8` and
`Set-Content` add one. `jobqueue.py` now tolerates it and logs loudly when it is
running on defaults — look for `config ... is UNREADABLE` in
`logs\jobqueue.log`. Write config with:

```powershell
[IO.File]::WriteAllText($p, $json, (New-Object Text.UTF8Encoding $false))
```

## A repeating scheduled task never repeats

If it has only a **logon trigger** and the user is already logged in, that
trigger fired at boot and `NextRunTime` is empty — it will never run again.
`AI-InputHeartbeat` had this exact bug and the console idle reading went
permanently stale. Add a `TimeTrigger` with a `StartBoundary` in the past
carrying the repetition.

## An installer or bridge command hangs forever

Two known causes:

- **`Start-ScheduledTask` inside a script.** The started process keeps the
  script's stdout pipe open, so any caller reading that output to completion
  blocks until the started task exits — i.e. never, for a resident runner. It
  looks exactly like a hung installer, and retrying creates a *second* runner.
  Print the start command instead of running it.
- **`Unregister-ScheduledTask` on a Running task.** It blocks until the task
  stops. Stop it and kill its processes first.

## Two GPU jobs landed on the same card

Someone skipped the lease. See [GPU leasing](03-gpu-leasing.md). If a stale
lease is blocking instead, `gpulease.py list` then `reap`; the broker also
automatically reaps expired, dead-owner, and reused-PID leases.

## `nvidia-smi` shows a card pinned at 120 W

The idle monitor's Tier 2 power cap. It restores on activity, and a live GPU
lease prevents it entirely. If it is stuck, take a lease or run
`idle-monitor.ps1 -ForceRestore`.

## A job is stuck in `running` and nothing is happening

Its runner probably died. `python jobqueue.py reap` requeues jobs whose PID is
gone or which exceeded `job_timeout_minutes`. This also runs at the top of every
tick, so it should self-heal within one poll.

## onnxruntime cannot find its CUDA DLLs

Import **torch before onnxruntime** — onnxruntime-gpu 1.22 links against the
CUDA/cuDNN copies torch bundles. `common.gpu_bootstrap()` does this for you.
onnxruntime-gpu 1.29 does **not** work here (it links CUDA 13). numba is pinned
to 0.61.2 and scipy to 1.14.1 because newer wheels ship DLLs this machine's
Application Control policy blocks.

## An upscale or extension looks wrong

Look at it — automated quality gates have been wrong here three separate times.
A seam, a smear or a repeated texture band means the image needed the
scene-aware `genfill` path, not deterministic extension. See
[Imaging](04-imaging.md).

## DSH model loading and generation

The production path is native llama.cpp, not an LM Studio API. DSH talks to the
local proxy at `http://127.0.0.1:1235/v1`; the proxy asks the long-lived host at
`http://100.71.113.77:1236` to switch models when needed. The host owns both GPU
leases and starts one Q6 model with 262,144 context, full layer offload,
Flash Attention, q8 K/V cache, and draft-MTP where the model supports it.

Check the state and service from PowerShell:

```powershell
ssh poopl@100.71.113.77 "type C:\AI-Server\state\llama-host\state.json"
ssh poopl@100.71.113.77 "curl.exe -s http://127.0.0.1:1236/v1/models"
```

The tested warm Q6 generation is about 47–48 tokens/second at 256K context.
If the host is asleep, run `dsh` again: the wrapper wakes it through the
Moonlight/wake relay before attempting SSH or model loading.

### `dsh -l` says the session is already running, but requests return 503

That message can mean the browser launcher is still listening on port 3080
while the remote llama.cpp process has died. Check all three layers:

```powershell
Get-NetTCPConnection -State Listen -LocalPort 3080,1235,1238
Test-NetConnection 100.71.113.77 -Port 1236
ssh poopl@100.71.113.77 powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\AI-Server\scripts\llama-host.ps1 -Action Status
```

The fixed wrapper only reuses an existing session when the two local proxies
and server port 1236 are reachable. Otherwise, run `dsh -l` again; it removes
the stale DSH launcher/proxies and starts a fresh held server session. Do not
delete session JSON files unless the DSH session itself is corrupt. A 503
`model_proxy_error` with `fetch failed` means the remote service is unreachable,
not that the browser token is invalid.

### Legacy LM Studio fallback

LM Studio is no longer the production model server. Do not edit its
`disabledGpus` or model-load settings to fix DSH. Use the native host state and
service checks above; the DSH wrapper owns wake, leases, model switching, and
the local proxy. The bundled LM Studio model files remain available as a
fallback source for llama.cpp.

## PowerShell mangles llama.cpp `-ot` values (2026-09-28)

`Start-Process -FilePath llama-server -ArgumentList $array` silently corrupts any
argument containing `| ( )` — e.g. the expert-placement regex
`-ot "ffn_(gate|up|down)_exps\.weight=CUDA_Host,..."` — even when the element is
double-quoted. llama-server then rejects it ("unknown buffer type") or drops the
override. Cost: an hour of "why is it still on the wrong binary / wrong buffer".

Fix used in `llama-host.ps1` and `tune.ps1`: write the exact command to a `.bat`
(quoting values with special chars) and launch that via `cmd /c`, then bind to
the resulting `llama-server` process by name (one runs at a time on :1236).

## The model proxy could not spawn the native host by Popen (2026-09-28)

`model-proxy.py` starting the `-Hold` native host with a detached
`subprocess.Popen` did not reliably work: the nested launcher never ran (empty
launch log, no `llama-server`). A CIM/`Start-Process` child of an SSH session
also dies on disconnect, and a session-0 process cannot cleanly spawn the
interactive-session launcher. Fix: the proxy writes the requested model to
`state\llama-host\requested-model.txt` and triggers the `AI-NativeHost`
scheduled task (LogonType Interactive, session 1), which reads that file and runs
`llama-host.ps1 -Action Start -Hold`. Scheduled tasks are the reliable way to
launch a persistent GPU host from a non-interactive context here.

## Editing state JSON from PowerShell 5 breaks `roles.json` (2026-09-29)

In Windows PowerShell 5.1, `ConvertTo-Json | Set-Content -Encoding UTF8` writes a
**UTF-8 BOM**. `config.load_roles()` opens `roles.json` with plain `utf-8`, so
every admin tool, and the email administrator, fails with
`JSONDecodeError: Unexpected UTF-8 BOM`. Edit state JSON (`roles.json`,
`jobqueue.json`) from Python instead, or write it with
`[IO.File]::WriteAllText($p, $json, (New-Object Text.UTF8Encoding $false))`.
Afterwards, check it with `admin_tools.py --as <email> my-access`.

## Developer SSH refused with a correct key: `Permission denied (publickey)` (2026-09-29)

Antoine's key was installed correctly (fingerprint matched, modes 700/600), yet
sshd on 2222 still refused it. The cause was that `setup.sh` ran `passwd -l antoine`,
which puts `!` in `/etc/shadow`. With `UsePAM no` (in `sshd_config_pp`), OpenSSH treats
a `!` hash as a **locked account** and rejects the user before reading
`authorized_keys`. The fix is `usermod -p '*' antoine`: there is still no usable password,
but the account is not locked. `setup.sh` now does this. Check it with
`grep '^antoine:' /etc/shadow | cut -d: -f2 | cut -c1`, which should print `*` and not `!`.

## pip fails over SSH with "WinError 448 ... untrusted mount point" (2026-10-07)

`pip install` in an SSH session aborted with `[WinError 448] The path cannot be traversed because it contains an
untrusted mount point: 'C:\Users\poopl\AppData\Local\Programs\OpenAI\Codex\bin'`. pip walks PATH entries to check
script locations, and the Codex `bin` folder is a mount point that network logons treat as untrusted. Fix: drop that
entry for the command, e.g. in PowerShell
`$env:PATH = ($env:PATH -split ';' | ? { $_ -notmatch 'OpenAI\\Codex' }) -join ';'` and add `--no-warn-script-location`.

## ssh from a SYSTEM queue job: "UNPROTECTED PRIVATE KEY FILE ... bad permissions" (2026-10-10)

A key made by poopl (`ssh-keygen` as poopl gives Administrators F, SYSTEM F, poopl M) works in poopl's shells but
is rejected when a queue job (SYSTEM) uses it: for SYSTEM, poopl counts as "another user". Give the key file only
SYSTEM and Administrators, owned by Administrators:
`icacls KEY /inheritance:r /grant:r SYSTEM:F /grant:r Administrators:F /remove poopl` and
`icacls KEY /setowner Administrators`. poopl is an administrator, so its ssh sessions can still use it. Used by
`C:\AI-Server\scripts\box.cmd` (key `C:\AI-Server\state\ssh\ai-server-2_ed25519`).

## BaseFinder parse hangs forever on Linux (AI Server 2), 0 % CPU (2026-10-10)

`parse_scraped18.py`'s scenery process pool never returned on AI Server 2. py-spy showed every worker inside
`cv2.setNumThreads(1)`: the parent had already started OpenCV's thread pool, and a **forked** child waits on a lock
whose owner thread does not exist in the child. Windows spawns its workers, so it never happened here. Fix: start the
parent with one OpenCV thread, `OPENCV_FOR_THREADS_NUM=1` (set by ClashEngineering `ops/strixhalo/jobs/basefinder_parse.sh`).
