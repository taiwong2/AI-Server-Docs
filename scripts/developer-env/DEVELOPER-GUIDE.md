# Your space on Tai's AI server

This is the developer guide for Antoine and his agents. The AI overseer
(email **twongclaude@gmail.com**) works from this same document. Decided by Tai
on 2026-09-25.

## What you have

- **Your own Linux machine, `pp-antoine`.** It runs Ubuntu 24.04 (WSL2) with a 50 GB disk. Both RTX 3090s are visible, and CUDA works.
  Python, git and build tools are installed. You are user `antoine`, without root: ask
  the overseer for apt packages. Build whatever you like here, including your own
  relay, APIs and pipelines.
- **LM Studio**, which is OpenAI-compatible:
  - From inside your machine: `http://127.0.0.1:1234/v1`
  - From pp-vps or your Mac over the tailnet: `http://100.71.113.77:1234/v1`
  - Use model `qwen3.8-27b`, one request at a time, batch work only. Back off on errors.
- **SSH into your machine** with `ssh -p 2222 antoine@100.71.113.77`. It is key-only, so send the
  overseer your public key first. It works only while a session is running.
- **Port 8899 on 100.71.113.77** forwards into your machine, for your own relay or
  API. Listen on `0.0.0.0:8899` inside.

## The rule: the server has to sleep

- Your machine runs **only during a booked session**. A session lasts up to **2 hours**. You get up to
  **4 hours per day**. Days follow the box's local time, which is US Pacific.
- When a session ends, your machine is stopped and every process is killed. Your files stay.
- The box sleeps when it is idle. While it is asleep it cannot read email, so **book ahead**.

## Running things on a schedule: no cron needed

Cron and systemd timers inside your machine will never fire, because the machine is off
between sessions. Use the session schedule instead:

1. Put your job in `~/autorun.sh` and make it executable (`chmod +x`). It starts
   automatically at the beginning of every session, and its output goes to `~/autorun.log`.
2. Ask the overseer to *"book a 60 min session daily at 03:00"*. The box wakes itself
   at that time, runs your autorun, and goes back to sleep when the session ends.
3. Your job is killed at the end of the session, so make it finish in time or checkpoint its work.

## GPU

- If your work uses CUDA, say so when you book, for example *"with 12 GB GPU"*. The overseer then
  reserves that much VRAM on one card and writes `~/.gpu-env`. Run
  `source ~/.gpu-env` to get `CUDA_VISIBLE_DEVICES`.
- Don't use a GPU without a reservation. Tai's jobs share both cards.
- LM Studio calls don't need a reservation.

## Network from inside your machine

- The public internet is open.
- These are blocked: Tai's home network, the tailnet, and services that run only on the
  Windows host. LM Studio on 1234 is the exception.
- For your own local services, use ports **20000-29999** on 127.0.0.1. Other loopback
  ports are blocked.

## What you can ask the overseer (email twongclaude@gmail.com)

| Ask | Example |
|---|---|
| Book time | "book a 90 min session at 02:00", "book 60 min daily at 03:00 with 12 GB GPU" |
| See or cancel | "list my sessions", "cancel session 1a2b3c", "stop my session now" |
| SSH key | "set my ssh key: ssh-ed25519 AAAA... me@mac" |
| Packages | "install apt packages: ffmpeg libpq-dev" |
| Status | "inference status", "what can I do?" |

## Not available (ask Tai)

- A Windows shell, SSH on port 22, or jobs in the server's own queue. Those jobs run as SYSTEM.
- Changes to Tai's services, or sessions longer than the caps.
- Kloow on Tai's account.
