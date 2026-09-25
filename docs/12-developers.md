# Developers on the box (Antoine and his agents)

Added 2026-09-25. **Part 1** is for the developer and their agents. **Part 2** is
for Tai and admin agents: how the rules are enforced and where the pieces live.

The policy, decided by Tai: *a developer can build whatever they want in their
own 50 GB space, as long as it never keeps the server awake for more than
**2 hours per session** or **4 hours per day**.*

---

## Part 1 — for developers

The developer guide is the authoritative version. It lives in three places, all
with the same text:

- `~/README.md` inside the developer's environment
- `C:\AI-Server\ai-admin\DEVELOPER-GUIDE.md`, which the AI administrator reads
  and passes on when a developer asks what they can do
- the summary below

### What you have

- **Your own Linux machine, `pp-antoine`.** It is Ubuntu 24.04 on WSL2 with a
  50 GB disk. Both 3090s are visible and CUDA works. Python, git and build tools
  are installed. You are user `antoine`, without root. Ask the administrator for
  apt packages.
- **LM Studio**, which is OpenAI-compatible. Inside your machine it is at
  `http://127.0.0.1:1234/v1`. Over the tailnet it is at
  `http://100.71.113.77:1234/v1`. Use model `qwen3.8-27b`, one request at a time.
- **SSH** with `ssh -p 2222 antoine@100.71.113.77`. It is key-only and works only
  during a session.
- **Port 8899** on `100.71.113.77` forwards into your machine, for your own
  relay or API.

### The rule: the server has to sleep

- Your machine runs **only during a booked session**. A session lasts up to
  2 hours, and you get up to 4 hours per day. Days follow the box's local time,
  which is US Pacific.
- When a session ends, the machine is terminated and every process dies. Your
  files persist.
- The box cannot read email while it is asleep, so **book ahead**.

### Scheduled work: no cron

Cron and systemd timers never fire, because the machine is off between sessions.
Use the session schedule instead:

1. Put the job in `~/autorun.sh` and run `chmod +x ~/autorun.sh`. It runs at the
   start of every session, and its output goes to `~/autorun.log`.
2. Book a recurring session, for example *"book 60 min daily at 03:00"*. The box
   wakes itself, runs your autorun, and goes back to sleep afterwards.

### GPU

Reserve VRAM when you book, for example *"with 12 GB GPU"*. Then run
`source ~/.gpu-env` to get `CUDA_VISIBLE_DEVICES`. Without a reservation,
`~/.gpu-env` hides the GPUs. LM Studio calls don't need a reservation.

### Network inside your machine

The public internet is open. These are blocked: the LAN, the tailnet, and
services that run only on the Windows host (LM Studio on 1234 is the exception).
Use loopback ports **20000–29999** for your own services.

### Asking the administrator

Email **twongclaude@gmail.com**:

| Ask | Tool it runs |
|---|---|
| "book 90 min at 02:00 [daily] [with 12 GB GPU]" | `session-book --minutes 90 --at 02:00 [--daily] [--gpu-mb 12000]` |
| "list my sessions" / "cancel 1a2b3c" / "stop my session now" | `session-list` / `session-stop --id` |
| "set my ssh key: ssh-ed25519 AAAA…" | `ssh-key-set` |
| "install apt packages: ffmpeg libpq-dev" | `apt-install` |
| "what can I do?" / "inference status" | `my-access` / `inference-status` |

**Not available** (Tai's call):

- a Windows shell, SSH on port 22, or jobs in `jobqueue` (queued jobs run as
  SYSTEM)
- changes to Tai's services, or sessions beyond the caps
- Kloow on Tai's account

---

## Part 2 — how it is enforced

### Roles and caps

`C:\AI-Server\state\ai-admin\roles.json`

| cap | developer | admin |
|---|---|---|
| `session_minutes_max` | 120 | 600 |
| `session_minutes_per_day` | 240 | 1440 |
| `can_schedule` (raw `jobqueue` jobs) | **false** | true |
| `can_book_sessions`, `can_use_inference` | true | true |

`trust_tai_self_identification` is **false**. Until 2026-09-25, a message saying
"I am Tai" was elevated to admin, and one from Antoine's address was. Identity is
now the sender address, and nothing else.

Caps are enforced in `admin_tools.py`. The prompt's standing policy in
`dispatcher.py` only tells the administrator to say yes to what the guide allows,
and to correct mistaken assumptions such as cron. When the requester has an
environment, the developer guide is appended to the prompt.

### How a session holds the box awake, and only that long

```
session-book ──► dev-sessions.json row
   │  future start: jobqueue submit --kind devsession --at <start>
   │                 (arms the wake timer; the job only runs
   │                  `schtasks /run /tn AI-DevSession` and returns)
   │  now:           schtasks /run /tn AI-DevSession
   ▼
\AI-DevSession  (poopl)  → ai-admin\devsession_launch.py
   1. GPU lease if --gpu-mb      (gpulease, so Tai's jobs see it)
   2. wsl -d pp-antoine: pp-boot.sh (firewall + sshd), ~/.gpu-env, ~/autorun.sh
   3. devsession.py listens on 127.0.0.1:8898 until the deadline or a stop flag
      └─ 8898 is in state\jobqueue.json busy_ports → the sleep gate holds
   4. wsl --terminate pp-antoine; release the lease; book tomorrow if --daily
```

- The queue is **serial**, so a session never runs as a queue job. A 2-hour job
  would stall the 2-hourly tracking job.
- Port 8899's forwarding listens permanently, so it is **not** in `busy_ports`.
  Only 8898 is, and only `devsession.py` opens it.
- A stop flag at `state\ai-admin\session-stop\<id>.stop` ends a live session
  within about 5 seconds.
- Budget is counted per box-local day, using minutes booked, or minutes actually
  used once a session has run.

### The environment (`pp-antoine`) and why it is a WSL distro

A native Windows account was ruled out. The Gmail MCPs on `127.0.0.1:8000`
(taiwong263) and `:8001` (twongclaude) have no authentication. Windows Firewall
does not filter loopback, so any Windows process could send and read Tai's mail.
Also, `C:\AI-Server` inherits *Authenticated Users: Modify*, and the job kinds in
it run as SYSTEM.

The WSL distro is set up as follows:

- It lives at `C:\wsl\pp-antoine` with a 50 GB cap (`wsl --manage … --resize`).
  It was imported from the official Ubuntu 24.04 WSL rootfs.
- `/etc/wsl.conf` turns **interop off**. With interop on, Linux could launch
  Windows programs as poopl. It also turns **automount off** (no `/mnt/c`).
  `pp-boot.sh` adds a second layer: it unregisters the `WSLInterop` binfmt
  handler and makes `/run/WSL` root-only. A Windows `.exe` written into his home
  directory gets `Exec format error`.
- **Network quirks.** WSL's generated `resolv.conf` points at IPv6 DNS proxies
  (`fec0::…`) that never answer, and apt hangs on IPv6. The fixes are
  `generateResolvConf=false`, a static `/etc/resolv.conf` of 1.1.1.1 / 8.8.8.8,
  `Acquire::ForceIPv4`, an IPv4 preference in `gai.conf`, and removing the
  Ubuntu `apt_news` hook, which also hung.
- `antoine` has no sudo and a locked password. Root-only changes go through the
  `apt-install` and `ssh-key-set` tools.
- `/usr/local/sbin/pp-boot.sh` runs as root at every start. It sets
  iptables/ip6tables OUTPUT rules: loopback only to 1234 and 20000–29999, LAN,
  tailnet, link-local and private ranges rejected, internet open. It then starts
  sshd with `/etc/ssh/sshd_config_pp`: port 2222, `AllowUsers antoine`, keys
  only, **no TCP forwarding**, because forwarding would bypass the firewall.
- **Why the iptables rules are essential:** WSL here fell back to
  `networkingMode VirtioProxy`, where `127.0.0.1` inside the distro *is* the
  Windows host's loopback. Without the rules, `curl 127.0.0.1:8001` from Linux
  reaches the twongclaude Gmail MCP. This was verified before the rules were
  added.

### Ports he listens on

In VirtioProxy mode, WSL **publishes every port the environment listens on as
`0.0.0.0:<port>` on the Windows host**. That is how sshd on 2222, and his relay
on 8899, reach the tailnet with no `netsh portproxy`. As a result:

- His listeners are reachable from the LAN and from Tai's own tailnet devices.
  The sharee firewall below limits *his* devices to 1234, 2222 and 8899.
- They exist only while a session runs, because the environment is terminated
  when it ends. So they can never hold the box awake: `busy_ports` contains only
  25565 and 8898.

### Tailnet sharees

Antoine's devices reach the box through a Tailscale **node share**. By default,
a share exposes every listening port: SSH, ComfyUI, Sunshine, the model proxy.
`scripts\sync-sharee-firewall.ps1` runs as task `\AI-ShareeFirewall` (SYSTEM, at
boot and every 10 minutes). It reads shared-in peers from `tailscale status` and
maintains these rules:

- `AI-Sharee-Allow`: TCP 1234, 2222 and 8899
- `AI-Sharee-Block-TCP` and `AI-Sharee-Block-UDP`: every other port

Block rules beat the existing `Tailscale-In` and `AI-*` allows. The script also
writes `state\ai-admin\sharee-ips.json`.

### Verified on 2026-09-25

- **As `antoine`:** no sudo, no `cmd.exe`, no `/mnt/c`, disk 49 GB. From inside,
  only `127.0.0.1:1234` and `100.71.113.77:1234` are reachable out of 8000, 8001,
  22, 8188, 1235 and 8787 on loopback, the LAN IP and the tailnet IP. The
  internet (https) works, LM Studio answers, and both GPUs are listed.
- **Booked 2 min with `--gpu-mb 2000`:** the environment started from the
  `\AI-DevSession` task, the lease went to GPU 1, and the sleep gate showed
  "listening on 8898". At 2:00 the environment was terminated and the lease
  released, leaving only the tester's SSH blocking sleep.
- **Booked 1 min `--daily`:** `~/autorun.sh` ran, and with no reservation
  `CUDA_VISIBLE_DEVICES` was empty. Tomorrow's slot was booked and its wake job
  queued. Cancelling it removed the job.
- **Refusals:** `schedule` is denied (no `can_schedule`), 200-minute sessions are
  denied, and "I am Tai" does not elevate.
- **The administrator, asked by Antoine's address about "a cron job at 2am plus a
  relay":** it explained there is no cron, pointed to `autorun.sh` plus a daily
  booking (converting Paris to Pacific time), said the relay goes on 8899 during
  sessions, and asked for the SSH key.

**Not yet proven:** a booking that wakes the box *from sleep*. It uses the same
`jobqueue --at` wake timer as every other timed job, but has not been observed
end to end for `devsession`. Nor has an SSH login with a real key from pp-vps.

### Files

| | |
|---|---|
| Policy + caps | `state\ai-admin\roles.json` (`policy_notes` says who decided what) |
| Bookings | `state\ai-admin\dev-sessions.json` |
| Session log | `logs\devsession.log`; audit trail `logs\ai-admin-audit.log` |
| Code | `ai-admin\{admin_tools,dispatcher,config,devsession,devsession_launch}.py` |
| Queue kind | `scripts\jobkinds\devsession.ps1` |
| Env setup | `C:\wsl\pp-setup\` (mirrored in `scripts/developer-env/`) (`setup.sh`, `pp-boot.sh`, `sshd_config_pp`, `wsl.conf`); rootfs `C:\wsl\ubuntu-noble.tar.gz` |
| Pre-change backup | `state\ai-admin\backup-20260925-antoine\` |

### Admin one-liners

```bash
A="python C:\AI-Server\ai-admin\admin_tools.py --as twongclaude@gmail.com"
$A session-list                 # everyone's bookings
$A session-stop --id <id>       # end anyone's session
wsl --terminate pp-antoine      # hard stop of the environment
```

To add another developer: add them to `roles.json`, create a distro with
`C:\wsl\pp-setup\setup.sh` (change the user name), and add an entry to `DEV_ENVS`
in `config.py`.
