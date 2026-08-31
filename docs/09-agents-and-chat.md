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
- **The bot runs on the mini (`wake-relay`), not here.** The
  `state\discord-bridge\bot-on-mini` marker makes `start-services.ps1` skip it —
  two gateway connections on one token kick each other off. The mini receives
  the message, wakes this box if it is asleep, then dispatches over ssh to
  `dispatch_once.py`. Bot code: `/Users/workbot/wake-watch/mini_bot.py`, reachable
  as `ssh root@100.127.179.9`. To enable: create a Discord bot, turn on the **Message Content Intent**,
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
- **Intake**: `email_intake.py --loop` polls twongclaude via the admin Workspace
  MCP (:8001) and auto-starts from `start-services.ps1`; `admin-*` Discord
  channels route to the same brain.

The driving example — "raise Antoine 20 GB → 40 GB" — is a real, enforced
`quota.py resize` (verified end-to-end).

## Managing channels programmatically (added 2026-08-31)

`C:\AI-Server\scripts\discord_admin.py` does channel administration without a
browser. Stdlib only, so it runs under any python on the box, and it reads the
bot token from the ACL-locked `token.env` itself — the token never has to be
passed in or printed.

```bash
PY="C:\Users\poopl\AppData\Local\Programs\Python\Python312\python.exe"
D="C:\AI-Server\scripts\discord_admin.py"

$PY $D guild-info                                  # bot identity + every channel id
$PY $D create-channel --name qwen-my-topic --topic "..."
$PY $D post --channel <channel-id> --file findings.md
```

`post` splits on blank lines to respect the 2000-character message cap without
cutting mid-line, so Markdown survives, and it backs off on HTTP 429.

Because **naming a channel chooses its backend**, `create-channel --name
qwen-foo` creates a live Qwen session in one call.

**The bridge ignores bots and webhooks by design**, so a message the bot posts
never triggers a backend. Posting *records* output; it does not ask a question.
Do not build a loop that expects the bot to answer itself.

## Research jobs on the local model (added 2026-08-31)

`jobkinds\qwenresearch.ps1` plus `scripts\research_qwen.py` run the local Qwen
through a deep-research topic and post the result to Discord — one topic per
job, so a run stays inside `job_timeout_minutes` and each topic gets its own
log, retry and result file.

```bash
python C:\AI-Server\scripts\jobqueue.py submit --kind qwenresearch --arg TopicId=01
```

Two things learned building it:

- Set `PYTHONUNBUFFERED=1` in any job handler that shells out to python, or
  nothing reaches the job log until the process exits and a healthy run looks
  exactly like a hung one.
- A small model will invent plausible arXiv ids unless the prompt forbids it in
  as many words. The driver's `METHOD` block does; reuse its shape. Treat local
  research output as a draft and check citations resolve.

## The agent had no context management (fixed 2026-08-31)

`agent.py` appended every tool result verbatim and never trimmed. Nothing
compacted, summarised or truncated — so a session grew until it exceeded what
the model could attend to, and then quietly got worse rather than failing.

Measured: one research dive reached **722 KB (~200k tokens) in a single turn**,
because `web_fetch` returns up to 150 KB and the model called it repeatedly. A
long-lived Discord channel walks the same path, only slower.

`qwen-agent\compact.py` now runs before every model call:

- **Elision, not summarisation.** No extra model call, deterministic, free.
- **Messages are never dropped.** A tool message is kept with its
  `tool_call_id` and only its *content* is shortened. Deleting a tool message
  whose assistant `tool_call` still exists produces an invalid conversation the
  API rejects — that is the trap to avoid.
- **What survives untouched:** the system prompt, the first user message (the
  task), the last few exchanges, and the single most recent tool result.
- **Sent, not stored.** The full history stays on disk; only what goes to the
  model is compacted. Nothing is destroyed.

On the real 722 KB dive session: **722 KB -> 81 KB (~200k -> ~22k tokens), 89%
saved**, conversation still valid, and idempotent.

Tuning note: `KEEP_RECENT` is deliberately **4**, not 10. These dives make few
enormous tool calls rather than many small ones, so a large protected tail
shields nearly all the bulk — at 10 it only saved 22%.

Only new processes pick this up; a job already running has `agent.py` loaded.

## A live bot process is not a live bot (2026-08-31)

`mini_bot.py` had been running for two days and Discord was silent. The process
was healthy; the **gateway connection was not** — the last `mini bot online`
line was 34 hours old and nothing had noticed.

What hid it: a supervisor respawns the bot every ~10 seconds, each attempt
correctly refuses on the lock file, and writes `another mini_bot instance
already holds the lock; exiting`. That fills the log so completely that the
absence of real activity is invisible. Always filter it:

```bash
ssh root@100.127.179.9 "cd /Users/workbot/wake-watch && \
  grep -v 'already holds the lock' mini-bot.log | tail -20"
```

Fix is a plain `kill <pid>`; the supervisor retakes the lock within ~10s and
logs a fresh `mini bot online`.

## qwen channels compete with local research

One LM Studio instance serves both. With a research dive running, an 8-token
request measured **30 seconds**. Chat works but crawls; a turn with tool calls
can take many minutes. `claude-*` channels are unaffected. Pause the queue if
someone needs the local model interactively.
