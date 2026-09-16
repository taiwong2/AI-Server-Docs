---
name: ai-server-jobs
description: Run work on Tai's AI server (2x RTX 3090) through its job queue - submit now or on a schedule, check status, read results. Use whenever work should run on the GPU box rather than locally, when a task is long enough to outlive the current session, when scheduling something overnight, or when the server may be asleep and needs waking by queueing work.
---

# Running work on the AI server

The server sleeps when idle and wakes for queued work. Submitting a job is both
how you run something *and* how you wake the machine.

```bash
Q="C:/AI-Server/scripts/jobqueue.py"          # on the server
# from elsewhere: ssh poopl@192.168.1.24 (LAN) or poopl@100.71.113.77 (Tailscale)
```

## Before anything else

```bash
python $Q status
```

It prints what is queued, when the box next wakes, and — critically — **why it
is or is not asleep**. If something you expect is not running, this is the
answer, not a guess.

## Submitting

```bash
python $Q submit --kind image  --arg Src="C:\pics\a.jpg" --arg Out="C:\AI-Server\out\a"
python $Q submit --kind claude --arg Prompt="run the nightly check" --at 03:00
python $Q submit --kind shell  --arg cmd="nvidia-smi" --in-minutes 30
```

`--at HH:MM` means the next such time and **wakes the machine**. `--priority N`
jumps the line.

## Watching

```bash
python $Q list                 # queue + last 5 done and failed
python $Q cancel <id-prefix>
```

Per-job output is at `C:\AI-Server\logs\jobs\<job-id>-<kind>.log`. Read it —
"exit 0" is not the same as "did the right thing".

## Choose the queue over inline execution when

- the work takes more than a couple of minutes
- it needs a GPU (the queue serialises against training runs via leases)
- the box might be asleep
- the result must survive your session ending

Inline work dies with your session and leaves half-written output.

## Adding a capability

Job kinds are files: `C:\AI-Server\scripts\jobkinds\<kind>.ps1` or `.py`. Every
`args` key arrives as `-Name Value` / `--name value`. No change to the broker.

A handler must **exit non-zero on failure**, **never prompt** (SYSTEM has nobody
to answer, so it hangs forever), and **resolve paths explicitly** — it runs as
SYSTEM, whose `$env:USERPROFILE` is `C:\WINDOWS\system32\config\systemprofile`,
not the interactive user's. That trap has bitten twice here.

Keep the real algorithm in a versioned repo; the handler is only a launcher.

## Do not

- Do not sleep, shut down, or repower the machine. The queue runner owns that.
- Do not run a long GPU job outside the queue and outside a lease.
- Do not treat an empty `Get-ScheduledTask` as proof the runner is dead —
  SYSTEM tasks are invisible to unelevated queries.

Full reference: `docs/02-job-queue.md` in the ai-server-handbook repo.
