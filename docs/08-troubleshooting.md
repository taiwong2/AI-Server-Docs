# Troubleshooting

Symptoms first, with the answers that were expensive to find.

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
lease is blocking instead, `gpulease.py list` then `reap`.

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
