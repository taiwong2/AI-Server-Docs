# Remote access

| Route | Address | Notes |
|---|---|---|
| SSH (LAN) | `poopl@192.168.1.24` | 10 GbE, primary |
| SSH (anywhere) | `poopl@100.71.113.77` | Tailscale, node `ai-server` |
| Sunshine / Moonlight | 192.168.1.24 | desktop streaming |
| LM Studio API | `:1234` | **LAN only — no auth. Never expose it.** |
| ComfyUI | `:8188` | when running |

## Tailnet

| Node | Address | What it is |
|---|---|---|
| `ai-server` | 100.71.113.77 | this machine |
| `wake-relay` | 100.127.179.9 | macOS, on the LAN at 192.168.1.63 — wakes the server |
| `tais-macbook-air` | 100.64.83.97 | usually offline |

Tailscale SSH is enabled on `wake-relay` and authorises this server (a
connection attempt is rejected only for an unknown *local user*, not for
permission). You need the relay's macOS username to use it.

## Keeping a session alive over SSH

Use tmux. A dropped connection otherwise kills whatever you were running:

```bash
work            # attaches or creates the persistent tmux session
tmux ls
```

Better still, for anything long: put it in the queue instead
([The job queue](02-job-queue.md)). A queued job survives the connection, the
session, sleep, and reboot.

## If it does not answer

It is probably asleep, not broken. See [Wake and power](05-wake-and-power.md).
Check in this order:

1. `ping 192.168.1.24` — no answer and no wake means asleep or off.
2. Wake it: `./wake-pc.sh` from a LAN device, or via the relay from anywhere.
3. Still nothing after ~20 minutes? The heartbeat should have fired by then, so
   suspect the wake path — see the "Not yet proven" note in
   [Wake and power](05-wake-and-power.md).

## Credentials

Never in a repo, a prompt, or a log line. They resolve through
`C:\AI-Server\state\credentials\` (ACL-locked to the owner and SYSTEM) or, in
the Korean Pharmacy repo, through `tools/creds.py`.

Google Workspace access (Gmail, Drive, Docs, Sheets, Calendar) runs through a
local MCP server on port 8000 for **taiwong263@gmail.com**.
