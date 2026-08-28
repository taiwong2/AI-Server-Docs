# Agents, chat, and the AI administrator

How to talk to the server conversationally, run the local model as an agent, and
where the (in-progress) AI administrator is headed. Added 2026-08-27.

## Idle GPU no longer throttles job starts

The idle monitor used to cap **both GPUs to 120 W** after 20 minutes idle and
only restore full power on its next 60-second poll — so any job started after an
idle period crawled for up to a minute. Removed 2026-08-27: an idle 3090 already
draws ~20 W, so the cap saved almost no power and only ever penalised the start
of real work. Idle savings now come from model-unload (Tier 1) and the Balanced
CPU plan (Tier 2); the GPU watt cap is gone. For **guaranteed** full power on a
job, take a [GPU lease](03-gpu-leasing.md) — a lease also makes the idle monitor
leave the cards entirely alone.

## Discord bridge — a channel is a session

Message the server from a Discord server. Each **channel** is one persistent
conversation; the **backend** is chosen by the channel-name prefix:

| Channel name      | Backend                                            |
|-------------------|----------------------------------------------------|
| `qwen-*` / `qwen` | Local Qwen agent (see below)                       |
| `claude-*`        | Headless Claude Code (`claude -p --resume`)        |
| `main`            | Relay to the interactive terminal Claude session   |
| anything else     | `DEFAULT_BACKEND` (default `claude`)               |

- Code: `C:\AI-Server\discord-bridge\` (`bot.py`, `backends.py`, `README.md`).
- Config: `C:\AI-Server\state\discord-bridge\token.env` (ACL-locked; bot token +
  allowlist). **Security**: only an allowlisted user id in an allowlisted guild
  is served; bots, webhooks and DMs are ignored; with no allowlist it ignores
  everything. Both backends run **as poopl with full privileges** — the
  allowlist is mandatory.
- Auto-starts from `start-services.ps1` (step 6c), self-skipping until a token is
  set. To enable: create a Discord bot, turn on the **Message Content Intent**,
  put the token + your user/guild ids in `token.env`, restart.
- `#main` relay: messages become JSON tickets in `state\discord-bridge\main-inbox\`;
  the interactive session replies via `reply_main.py` -> `main-outbox\`.

## Qwen agent — the local model as an agent

`C:\AI-Server\qwen-agent\` drives `qwen3.8-27b-uncensored` (via LM Studio) in an
agentic tool loop: `run_shell` (PowerShell), `read_file`, `write_file`,
`list_dir`, `web_fetch`, `web_search`.

- Default working dir: `C:\AI-Server\qwen-workspace`. Full-machine reach by
  design; **file deletion is blocked** (no delete tool + a shell denylist) — but
  that guard is **advisory, not enforced**: an arbitrary shell can still delete.
  Real containment (a workspace VM) is a deferred follow-up.
- Slow: ~1–2 min per model call on this hardware, several per task. Reasoning
  effort defaults to `low` for loop latency (`qwen-agent\config.py`,
  `QWEN_REASONING_EFFORT` = low|medium|xhigh).
- Try it: `python C:\AI-Server\qwen-agent\cli.py --repl --session test`

## AI administrator — in progress

Goal: a role-aware admin you (and agents) chat with, that manages scheduling,
resources and access. **Status 2026-08-27: designed, not yet built.** It depends
on the job-queue runner being installed (see [Wake and power](05-wake-and-power.md))
and a dedicated admin Gmail account.

Planned shape:

- **Roles** (`roles.json`): identity (Gmail / Discord id) -> role. `admin` (Tai)
  = unrestricted; `developer` (e.g. Antoine) = request resources up to caps, run
  jobs, manage own workspace; `guest` = read-only. Every request is evaluated
  against the requester's role.
- **Intake**: a dedicated admin Gmail + the Discord bridge, feeding one handler.
- **Brain**: a role-aware Claude session per requester with admin tools.
- **Capabilities**: schedule/queue jobs (`jobqueue.py` + `gpulease.py`), manage
  cron schedules, start/stop services (incl. COBBLEVERSE so it stops pinning the
  box awake), report status, and **per-agent disk quotas via VHDX** — a
  fixed-size virtual disk per agent so "resize Antoine 20 GB -> 40 GB" is a real,
  enforced `Resize-VHD`, without a full VM.
- **Autonomy + escalation**: acts directly within a role's caps; escalates
  over-cap requests to the admin for approval. Every action audit-logged.

The first concrete request driving the design: a developer agent asking to raise
its workspace from 20 GB to 40 GB — handled by the VHDX quota primitive above.
