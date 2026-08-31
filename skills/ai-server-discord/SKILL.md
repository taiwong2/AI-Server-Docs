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

## When the bridge is not responding

The bot is a separate process from the queue runner; the queue can be perfectly
healthy while the bot is down.

```bash
ssh ai-server "powershell -NoProfile -Command \"Get-CimInstance Win32_Process -Filter \\\"Name like '%python%'\\\" | Where-Object { \$_.CommandLine -match 'discord|bot.py' } | Select-Object ProcessId,CommandLine | Format-List\""
```

No output means the bot is not running. It auto-starts from
`start-services.ps1` (step 6c) and self-skips until a token is set. Log:
`C:\AI-Server\logs\discord-bridge.log`.

Check `Message Content Intent` is on in the Discord developer portal — without
it the bot receives empty message bodies and looks broken while "working".

## Security — the part that is not optional

- Only an **allowlisted user id in an allowlisted guild** is served. Bots,
  webhooks and DMs are ignored. With no allowlist it ignores everything.
- Both backends run **as poopl with full privileges**. The allowlist is the only
  thing between a Discord message and a shell on this box. Never widen it
  casually, and never add a channel to a guild you do not control.
- Config lives in `C:\AI-Server\state\discord-bridge\token.env` (ACL-locked).
  Never commit it, never echo it, never paste a token into a prompt or a log.

## Do not

- Do not paste the bot token anywhere. Read it only through `discord_admin.py`.
- Do not assume a posted message will wake a backend — it will not.
- Do not delete channels to "clean up"; a channel is a conversation history.

Full reference: `docs/09-agents-and-chat.md` in the AI-Server-Docs repo, and
`C:\AI-Server\discord-bridge\README.md`.
