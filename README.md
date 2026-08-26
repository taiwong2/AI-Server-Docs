# AI Server Handbook

How to use Tai's AI server — written for **agents**, not just people.

If you are an agent that has just been pointed at this machine: read
[`AGENTS.md`](AGENTS.md) first. It is short, and it is the part that stops you
breaking something.

---

## What this machine is

A workstation-class box that does GPU work on demand and **sleeps when nobody
needs it**. Two RTX 3090s, 96 GB RAM, a 16-core Ryzen. It runs local LLM
inference, image generation and upscaling, model fine-tuning, and headless
Claude Code sessions.

The three things that make it different from a laptop you SSH into:

1. **It may be asleep.** It suspends to S3 when its queue is empty. You wake it
   by queueing work — see [Waking it](docs/05-wake-and-power.md).
2. **The GPUs are shared.** Never pick a card yourself. Take a lease. Two jobs
   that both "picked the freest GPU" once landed on the same card while the
   other idled — see [GPU leasing](docs/03-gpu-leasing.md).
3. **Long work belongs in the queue, not in your session.** A queued job
   survives your session ending, the box sleeping, and the machine rebooting.

---

## Start here

| I want to… | Read |
|---|---|
| Understand the machine before touching it | [Orientation](docs/01-orientation.md) |
| Run something (now, later, or while it sleeps) | [The job queue](docs/02-job-queue.md) |
| Use a GPU without fighting other jobs | [GPU leasing](docs/03-gpu-leasing.md) |
| Upscale or fix an image | [Imaging](docs/04-imaging.md) |
| Wake it, or understand when it sleeps | [Wake and power](docs/05-wake-and-power.md) |
| Reach it from another machine | [Remote access](docs/06-remote-access.md) |
| Not repeat an expensive mistake | [Best practices](docs/07-best-practices.md) |
| Fix something that is broken | [Troubleshooting](docs/08-troubleshooting.md) |

Agent skills live in [`skills/`](skills/) — drop them into a project's
`.claude/skills/` (or your harness's equivalent) and an agent gains these
capabilities with the guardrails attached.

---

## The 60-second version

```bash
ssh poopl@192.168.1.24          # LAN
ssh poopl@100.71.113.77         # anywhere, via Tailscale

Q="C:/AI-Server/scripts/jobqueue.py"

python $Q status                                  # is it busy? why is it awake?
python $Q submit --kind image --arg Src="C:\pics\a.jpg"
python $Q submit --kind claude --arg Prompt="..." --at 03:00
python $Q list                                    # queue + recent results
```

If the box does not answer, it is asleep. Wake it:
[Waking it](docs/05-wake-and-power.md) — from the LAN it takes seconds.

---

## What is where

| | |
|---|---|
| Machine scripts | `C:\AI-Server\scripts\` |
| Runtime state (queue, leases, config) | `C:\AI-Server\state\` |
| Logs | `C:\AI-Server\logs\` |
| Models | `C:\AI-Server\models\` |
| Imaging pipeline (versioned) | `korean-Pharmacy-Workspace/tools/imaging/` |

`C:\AI-Server` is **not** a git repository. The scripts are mirrored into
`korean-Pharmacy-Workspace/ops/ai-server-scripts/` for history. Edit the live
copies; keep the mirror in sync.

---

## Status of this handbook

Written 2026-08-25 against the machine as it actually is, with every claim
checked on the box rather than assumed. Where something is **unverified**, it
says so — see the "Not yet proven" notes. Do not quietly upgrade an unverified
claim to a verified one; re-test it and update the file.
