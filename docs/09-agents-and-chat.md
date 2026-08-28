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

## AI administrator — built (2026-08-27)

A role-aware admin you and other agents talk to (by **email** to
twongclaude@gmail.com, or a Discord **`admin-*`** channel) that manages
scheduling, the GPU/job queue, per-agent disk quotas, and services. Full details
in `C:\AI-Server\ai-admin\README.md`. Summary:

- **Roles** (`state\ai-admin\roles.json`): `admin` (Tai, unrestricted) /
  `developer` (e.g. Antoine — 50 GB disk cap, own workspace, may schedule) /
  `guest` (default, ignored). Every request is evaluated against the sender's role.
- **Brain**: a role-aware headless Claude session; the requester identity is
  **pinned** so a prompt-injected request can't escalate. Caps are enforced in
  `admin_tools.py`, not just the prompt.
- **Capabilities**: `gpu-status`, `queue-status`, `list-jobs`, `schedule`
  (queues a job, wakes the box), `disk-set` (per-agent **VHDX** workspace —
  create/resize, hard-enforced via diskpart through the admin bridge), and
  `service` (start/stop COBBLEVERSE so it stops pinning the box awake, admin only).
- **Escalation**: over-cap requests (e.g. a developer asking for 200 GB) are
  denied with an explanation and pointed at admin approval — never bypassed.
- **Tai self-identification (owner policy)**: anyone who identifies as Tai (name
  "Tai"/"Tai Wong", or a body claim like "I am Tai" / "it's Tai" / "- Tai") is
  trusted as **admin**, whatever the sending address. Convenient but
  **deliberately spoofable** — a text claim is not proof, so effectively anyone
  who writes "I am Tai" gets full admin. Every elevation is audit-logged with the
  real sender; disable with `trust_tai_self_identification:false` in `roles.json`.
- **Intake**: `email_intake.py --loop` polls twongclaude via the admin Workspace
  MCP (:8001) and auto-starts from `start-services.ps1`; `admin-*` Discord
  channels route to the same brain.

The driving example — "raise Antoine 20 GB → 40 GB" — is a real, enforced
`quota.py resize` (verified end-to-end).
