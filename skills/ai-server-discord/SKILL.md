---
name: ai-server-discord
description: Talk to Tai's AI server through Discord, and manage its channels programmatically - create a channel, post findings into one, list what exists. Use when asked to put results in Discord, make a new Discord channel, chat with the local Qwen model or headless Claude from Discord, or when the Discord bridge bot is not responding.
---

# Discord on the AI server

## The one idea: a channel is a session

Each Discord **channel** is one persistent conversation, and the **channel-name
prefix** picks which backend answers it.

| Channel name | Backend |
|---|---|
| `qwen-*` / `qwen` | Local Qwen agent (`qwen3.8-27b-uncensored` via LM Studio) |
| `claude-*` | Headless Claude Code (`claude -p --resume`) |
| `admin-*` | The AI administrator (role-aware, enforces quotas) |
| `main` | Relay to the interactive terminal Claude session |
| anything else | `DEFAULT_BACKEND` (currently `claude`) |

So **naming the channel chooses the model**. A channel called
`qwen-llm-efficiency` is a live Qwen session; renaming it to `claude-foo` would
hand the same channel to Claude Code with a different history.

Guild: **AI Server** (`1543003111122149487`). Bot: `AI-Server-Bot`.

## Managing channels without a browser

`C:\AI-Server\scripts\discord_admin.py` — stdlib only, so it runs under any
python on the box. It reads the bot token from the ACL-locked bridge config, so
**the token never has to leave the machine**. Never print it.

```bash
PY="C:\Users\poopl\AppData\Local\Programs\Python\Python312\python.exe"
D="C:\AI-Server\scripts\discord_admin.py"

$PY $D guild-info                                   # bot identity + every channel id
$PY $D create-channel --name qwen-my-topic --topic "what this channel is for"
$PY $D post --channel <channel-id> --file C:\path\to\findings.md
```

`post` splits on blank lines to respect Discord's 2000-character message cap and
never cuts mid-line, so Markdown survives. It retries on HTTP 429.

Run it over ssh from anywhere:

```bash
ssh ai-server "$PY $D guild-info"
```

## Posting is not the same as prompting

The bridge **ignores bots and webhooks by design**. A message the bot posts will
never trigger a backend. So:

- to *record* output in a channel -> `discord_admin.py post` (works whether or
  not the bridge is running)
- to *ask* the model something -> a human types in the channel, or you drive the
  backend directly (`qwen-agent\cli.py`, or the `qwenresearch` job kind)

Do not build a loop that expects the bot to answer its own message.

## The bot does NOT run on the AI server

It runs on **the mini** (`wake-relay`, a Mac mini) so it never misses a message
and can wake the AI server on demand. `C:\AI-Server\state\discord-bridge\bot-on-mini`
is a marker that stops `start-services.ps1` launching a second copy — **two
gateway connections on one token kick each other off**, so do not "fix" a silent
bot by starting one on the server.

```
Discord ──▶ mini (mini_bot.py, user workbot, /Users/workbot/wake-watch)
              │  wakes the server if asleep, then
              └─ ssh poopl@ai-server  python C:\AI-Server\discord-bridge\dispatch_once.py
                                       └─ qwen agent | headless Claude Code
```

Reach the mini with Tailscale SSH: `ssh root@100.127.179.9` (node `wake-relay`).

## When the bridge is not responding

Check the mini first, not the server:

```bash
ssh root@100.127.179.9 "ps aux | grep mini_bot | grep -v grep"
ssh root@100.127.179.9 "cd /Users/workbot/wake-watch && grep -v 'already holds the lock' mini-bot.log | tail"
```

**A live process does not mean a live bot.** Observed 2026-08-31: `mini_bot.py`
had been running for two days, but the last `mini bot online` line was 34 hours
old — the gateway had gone stale and nothing noticed, because a supervisor was
respawning every 10s and correctly backing off on the lock file, which fills the
log with `already holds the lock` and hides the silence. Filter that line out or
you will read a healthy-looking log for a dead bot.

Restart is just killing it; the supervisor retakes the lock within ~10s:

```bash
ssh root@100.127.179.9 "kill <pid>"      # then re-check for 'mini bot online'
```

Other things worth checking, in order: `ssh poopl@ai-server` from the mini as
`workbot` (the dispatch path), and whether the Message Content Intent is still
on in the developer portal — without it the bot receives empty message bodies
and looks broken while "working".

## qwen channels and local research share one LM Studio

There is one model server. While a research job is running, a `qwen-*` channel
queues behind it — an 8-token request measured **30 seconds** mid-dive. Chat
still works, it is just slow, and a real turn with tool calls can take many
minutes. `claude-*` channels are unaffected: headless Claude Code never touches
LM Studio.

If someone needs the local model interactively, pause the research queue rather
than assuming the bridge is broken.

## Security — the part that is not optional

- Only an **allowlisted user id in an allowlisted guild** is served. Bots,
  webhooks and DMs are ignored. With no allowlist it ignores everything.
- Both backends run **as poopl with full privileges**. The allowlist is the only
  thing between a Discord message and a shell on this box. Never widen it
  casually, and never add a channel to a guild you do not control.
- Config lives in `C:\AI-Server\state\discord-bridge\token.env` (ACL-locked) and
  in `/Users/workbot/wake-watch/mini-bot.env` on the mini. Never commit either,
  never echo one, never paste a token into a prompt or a log.

## Do not

- Do not paste the bot token anywhere. Read it only through `discord_admin.py`.
- Do not assume a posted message will wake a backend — it will not.
- Do not delete channels to "clean up"; a channel is a conversation history.

Full reference: `docs/09-agents-and-chat.md` in the AI-Server-Docs repo, and
`C:\AI-Server\discord-bridge\README.md`.
