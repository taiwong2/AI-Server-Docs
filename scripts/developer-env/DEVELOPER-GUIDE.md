# Your space on Tai's AI server

This is the developer guide for Antoine and his agents. The AI overseer
(email **twongclaude@gmail.com**) works from this same document. Decided by Tai
on 2026-09-25; time limits lifted 2026-09-29.

## What you have

- **Your own Linux machine, `pp-antoine`.** It runs Ubuntu 24.04 (WSL2) with a 50 GB disk. Both RTX 3090s are visible, and CUDA works.
  Python, git and build tools are installed. You are user `antoine`, without root: ask
  the overseer for apt packages. Build whatever you like here, including your own
  relay, APIs and pipelines.
- **An LLM endpoint**, OpenAI-compatible (since 2026-10-12 it is the uncensored Qwen3.8-Flash-Next on Tai's second
  server; LM Studio and the 27B on this box are gone, the 3090s here are for training):
  - From inside your machine: `http://127.0.0.1:1234/v1` (`/v1/chat/completions`, `/v1/completions`, `/v1/responses`, `/v1/models`)
  - From pp-vps or your Mac over the tailnet: `http://100.71.113.77:1234/v1`
  - No API key needed. Any model id works and is answered by `qwen3.8-flash-next-uncensored`. Thinking is on by
    default; send `"reasoning_effort": "none"` to turn it off.
  - **Context is 262,144 tokens.** A longer request fails at once with `context_length_exceeded`: compact or trim the
    conversation, do not resend it. 3 such errors in 10 min block the endpoint for 15 min, and the same prompt sent
    more than 3 times in 10 min is refused.
  - Limits: at most 8,192 output tokens per request (larger `max_tokens` is lowered), one request at a time,
    6 per minute, 60 per hour, 400 per day, 3 h of model time per day. `GET /status` shows today's use.
  - The model is loaded on demand. When it is off, the first request turns it on and you may get
    `503` with `Retry-After` for 1-3 minutes (longer if that server is asleep). Honour `Retry-After` and `429`.
- **SSH into your machine** with `ssh -p 2222 antoine@100.71.113.77`. It is key-only
  (your key is already installed). TCP forwarding works, e.g. `ssh -p 2222 -L 20001:127.0.0.1:20001 ...`
  to reach one of your own services.
- **Port 8899 on 100.71.113.77** forwards into your machine, for your own relay or
  API. Listen on `0.0.0.0:8899` inside.

## Always on (since 2026-09-29)

Tai lifted the time limits. Your machine now runs **all the time**, and the box stays
awake for it. No booking is needed.

- SSH, port 8899 and your own services are up around the clock. Long-running daemons,
  relays and training runs are fine.
- Session and daily caps are gone. You no longer need bookings; any existing ones only add
  a GPU reservation and never stop your machine.
- If your machine is ever restarted (a reboot, `wsl --shutdown` or a crash), it comes back
  on its own within about a minute, and `~/autorun.sh` runs again. Use autorun to restart
  your daemons.

## Running things on a schedule

Your machine is always on, so **cron works now**. `~/autorun.sh`, which runs each time your
machine starts, is still the place to (re)launch long-running services.

## GPU

- Both RTX 3090s are visible with no reservation (`~/.gpu-env` no longer hides them).
- Tai's own jobs share both cards, so check `nvidia-smi` before a big job and prefer the
  card with free VRAM. No LLM runs on these cards any more; they are busy with Tai's training.

## Network from inside your machine

- The public internet is open.
- These are blocked: Tai's home network, the tailnet, and services that run only on the
  Windows host. The LLM endpoint on 1234 is the exception.
- For your own local services, use ports **20000-29999** on 127.0.0.1. Other loopback
  ports are blocked.

## What you can ask the overseer (email twongclaude@gmail.com)

| Ask | Example |
|---|---|
| Sessions (optional now) | "list my sessions", "cancel session 1a2b3c" |
| SSH key | "set my ssh key: ssh-ed25519 AAAA... me@mac" |
| Packages | "install apt packages: ffmpeg libpq-dev" |
| Status | "inference status", "what can I do?" |

## Not available (ask Tai)

- A Windows shell, SSH on port 22, or jobs in the server's own queue. Those jobs run as SYSTEM.
- Root or sudo inside your machine, or lifting its firewall. On this box those would
  reach Tai's private Windows services, so packages go through the overseer.
- Changes to Tai's services.
- Kloow on Tai's account.
