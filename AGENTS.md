# AGENTS.md — read this before touching the machine

You are an agent operating someone else's workstation. It has other work on it,
other agents may be running right now, and its owner uses it interactively. The
rules below are the difference between being useful and being a problem.

Applies to any harness: Claude Code, Codex, an SDK agent, a cron script.

---

## 1. Take a lease before you touch a GPU

Never call `nvidia-smi`, pick "the freest card", and start allocating. Free VRAM
is a snapshot; it says nothing about what another process is *about to*
allocate. Two jobs did exactly this on 2026-08-24 and both landed on GPU 0 —
322 W and 99% on one card while the other sat at 28 W.

```python
import sys; sys.path.insert(0, r"C:\AI-Server\scripts")
import gpulease
with gpulease.acquire(vram_mb=12000, job="my-task") as g:
    os.environ["CUDA_VISIBLE_DEVICES"] = str(g.gpu)
```

```bash
python C:\AI-Server\scripts\gpulease.py acquire --vram 20000 --job mytask --pid $$
python C:\AI-Server\scripts\gpulease.py list
```

Shell callers **must** pass `--pid`, or the lease is reaped a millisecond later.

A live lease also stops the machine sleeping under you. That is not a side
effect; it is the point.

**Both GPUs are healthy.** Do not write logic that avoids GPU 0.

## 2. Long work goes in the queue, not in your session

If it takes more than a couple of minutes, queue it. A queued job survives your
session ending, the box suspending, and a reboot. It is retried if the runner
dies, logged to its own file, and cleared from the queue when it finishes.

```bash
python C:\AI-Server\scripts\jobqueue.py submit --kind image --arg Src="C:\pics\a.jpg"
python C:\AI-Server\scripts\jobqueue.py submit --kind claude --arg Prompt="..." --at 03:00
```

Running a 40-minute render inside an interactive session means it dies with the
session and leaves a half-written output nobody can find.

## 3. Assume the machine may be asleep

It suspends when its queue is empty and nobody is using it. Before concluding
"the server is down", see [Waking it](docs/05-wake-and-power.md). Queueing work
through the remote inbox wakes it on its own; from the LAN a magic packet wakes
it in seconds.

## 4. Never sleep the machine yourself

Do not call `SetSuspendState`, `shutdown`, `rundll32 powrprof.dll`, or change
power plans. Exactly one thing decides when this box sleeps: the queue runner.
Two things racing to suspend a machine is a bug, and one of them will do it
while somebody is streaming.

## 5. Verify the effect, never the return path

This is the rule that has cost the most here. Every one of these *reported
success while doing nothing*:

- `Register-ScheduledTask` fails **non-terminatingly** when unelevated — it
  writes "Access is denied" to stderr and the script prints its success
  message.
- A gate that reads a config with a BOM throws, falls back to defaults, and
  announces it is configured.
- A face detector, an edge-quality gate, and a 12B vision judge each certified
  output that a human immediately rejected.

Check the thing you changed actually changed. Read the task back. Re-query the
value. Look at the image.

## 6. Observe a gate in BOTH states before trusting it

"It correctly says blocked" proves nothing when the blocker is permanently
present. A sleep gate here called `query session` (which does not exist on
Windows Home) and `Get-Process sunshine` (a resident service, always running) —
so it returned "someone is using the machine" forever and the box would never
have slept. It looked right the whole time it was being developed, because a
session genuinely was attached.

The test that matters is watching a gate go **clear**.

## 7. Paths resolve differently for scheduled tasks

The queue runs as **SYSTEM**, whose profile is
`C:\WINDOWS\system32\config\systemprofile`. `$env:USERPROFILE`, `$HOME`,
`%APPDATA%` and `~` all silently change meaning. A job that works when you run
it by hand can fail 0.2s in when the runner picks it up — that has happened
twice here.

Resolve interactive-user paths explicitly. Test as the account that will run it.

## 8. Do not commit credentials

Everything resolves through a creds helper or an ACL-locked env file under
`C:\AI-Server\state\credentials\`. Never put a key, token, or password in a
repo, a prompt, or a log line.

The `job_inbox` table is equivalent to shell access on this box — a row in it
becomes a command. Treat write access accordingly.

## 9. Leave the machine as you found it

- Temporary files go in a scratch directory, not in a repo.
- Restore any power/config setting you changed for a test
  (`wake-test.ps1 -Restore`).
- Release leases. The `with` block does it; a shell caller should call
  `release`.
- If you changed something in `C:\AI-Server\scripts\`, mirror it into
  `korean-Pharmacy-Workspace/ops/ai-server-scripts/` so it has version history.

## 10. Record what you learned

If you find something that cost you an hour, write it down in
[`docs/08-troubleshooting.md`](docs/08-troubleshooting.md) so the next agent
does not pay for it again. If a rule here turns out to be wrong, fix the rule —
do not work around it silently.

---

## Hard "do not"

- Do NOT install Ollama (LM Studio and llama.cpp are the stack here).
- Do NOT use WSL unless explicitly asked.
- Do NOT raise GPU power limits above 350 W (GPU 0) / 390 W (GPU 1).
- Do NOT expose the LM Studio API port externally — it has no auth.
- Do NOT disable the busy-port guard permanently; a listening game server means
  real people are connected.
