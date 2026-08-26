# Orientation

What this machine is, before you run anything on it.

## Hardware

| | |
|---|---|
| CPU | AMD Ryzen 9 9950X — 16 cores / 32 threads |
| RAM | 96 GB |
| GPU 0 | RTX 3090 24 GB — bus 01, Zotac, water-cooled, drives the display |
| GPU 1 | RTX 3090 24 GB — bus 03, ASUS, liquid-cooled |
| Storage | 1 TB Crucial P510 NVMe |
| Network | Marvell AQtion 10 GbE (primary, `192.168.1.24`), Wi-Fi 6E (disabled) |
| Motherboard | MSI MEG X670E ACE (MS-7D69) |

**Both GPUs are healthy.** An older investigation into GPU 0 thermal throttling
was resolved and retired; do not write code that avoids GPU 0 or steers work to
one card. Power limits: GPU 0 = 350 W, GPU 1 = 390 W. Do not exceed them.

Fan and pump curves live in the **MSI BIOS → Hardware Monitor**, not in any
Windows utility — Secure Boot plus HVCI block the drivers those tools need.

## Software

| | |
|---|---|
| OS | Windows 11 Home |
| Python (system) | 3.12, plus Miniconda3 |
| GPU env | conda env **`ai`** — `C:\Users\poopl\miniconda3\envs\ai\python.exe` |
| CUDA | 12.4 |
| Inference | LM Studio (port 1234) |
| Streaming | Sunshine (Moonlight clients) |
| Remote | OpenSSH (22), Tailscale |

**The heavy deps live only in the conda `ai` env** — torch, spandrel, rembg,
onnxruntime-gpu. The system python has none of them. Anything doing GPU work
must use the `ai` interpreter by explicit path (see AGENTS.md rule 7).

## The two things running all the time

**`AI-JobQueue`** — a SYSTEM scheduled task running
`C:\AI-Server\scripts\jobqueue.py run`. Owns the job queue *and* the decision to
sleep. Single-instance, restarts on failure, starts at boot.

**`AI-InputHeartbeat`** — runs as the interactive user every 2 minutes, writing
the console's idle time to `state\last-input.json`. Session 0 cannot read
console input at all, so without this the machine cannot tell whether somebody
is sitting at it.

There is also `AI-IdleMonitor`, which still handles the cheap tiers (unload
resident models at 10 min idle, cap GPUs to 120 W at 20 min). It **no longer
sleeps the machine** — that moved to the queue.

## Layout

```
C:\AI-Server\
  scripts\          jobqueue.py, gpulease.py, wake-test.ps1, wol-listen.py, ...
    jobkinds\       one file per job kind: image.ps1, claude.ps1
    mac\            wake-pc.sh — the Wake-on-LAN sender for a Mac
  state\
    queue\          one JSON file per job; done/ and failed/ archives
    gpu-leases\     one JSON file per live GPU reservation
    jobqueue.json   power policy, re-read every tick
    last-input.json console idle heartbeat
  logs\
    jobqueue.log    queue + sleep/wake decisions
    jobs\           per-job output, named <job-id>-<kind>.log
  models\
```

## Design principles you will see everywhere

**The filesystem is the coordination layer.** No daemon, no port, no database
for the queue or the leases — one JSON file per item in a directory. Anything
that can read a directory can see the state, in any language, including a
PowerShell script and a human with `type`.

**Crash safety over cleverness.** Every item records the PID that owns it. Any
process can reap items whose owner is gone. A job whose runner was killed is
requeued, not lost and not run twice.

**Fail closed on anything that could strand the machine.** The runner refuses to
sleep if it cannot first arm a way to wake back up.
