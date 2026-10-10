# AI Server 2: wake and power (2026-10-09)

AI Server 2 (the Clash battle box, [docs/15](15-ai-server-2-battle-box.md)) now sleeps when nobody needs it and wakes
for work, like AI Server 1 ([docs/05](05-wake-and-power.md)). The Linux version is a root daemon, `ai-power`.
Source of truth: ClashEngineering `ops/strixhalo/power/` (`install.sh`). Runbook: `ops/strixhalo/README.md`,
"Automatic sleep and wake".

## When it sleeps

One thing decides: `ai-power.service` (system unit, `Restart=always`). It suspends to RAM only when **every** gate
has been idle continuously for `grace_minutes` (**10**):

| gate | busy when |
|---|---|
| clashjobs | a job is running, or a queued job could start now. A job queued with `--at` for later only sets the wake time. |
| units | an active unit (system, or taiwong's user manager) named `clashjob-*`, `clashlab-league@*`, `keepawake-*`, `run-*` (anything started with `systemd-run`), `llm-model-fetch.service`, `apt-daily*`, `fwupd-refresh`, `snapd.refresh` |
| inhibitor | a logind *block* inhibitor on sleep (`systemd-inhibit --what=sleep CMD`) |
| processes | a command line matching `busy_processes`: engine / league / bench / designer / BaseFinder / `gpujob.py` / `wsync.py`, rsync / scp / curl / wget, apt / dpkg, ffmpeg, podman pull, compilers |
| ssh | an ssh session with a tty and input in the last `input_idle_minutes` (**15**), or an ssh command (no tty, which is how agents work) running now or in the last 15 min. Read-only polls (`clashjobs list/status/show/log`, `ai-power status`) do not count. |
| detached | processes left behind by a closed ssh session (tmux, nohup) other than idle shells |
| console | a local tty login with input in the last 15 min |
| llm | `llm-gufo.service` is running and had a connection on :8080 or wrote a log line in the last `llm_idle_minutes` (**15**), or started less than 15 min ago |
| ports | something listening on a `busy_ports` entry (none by default) |
| cpu | whole-box CPU above 12 % (1-minute average): catches work nobody tagged |
| network | NIC traffic above 1.5 Mbit/s (1-minute average): catches big transfers |

`clashlab-update.service` (a 10-60 s site rebuild every 10 min) only **postpones** the suspend while it runs. It does
not restart the grace window, or the box would never sleep. A clashjob scheduled to start within about 4 minutes
also postpones it.

`ai-power status` names the gate holding it awake. Other agents' work holds the box by itself: clashjobs, their
`systemd-run` units, their tmux / nohup processes and their ssh commands are all gates.

It suspends to RAM in **s2idle** mode. That is the only mem state this firmware offers (`/sys/power/mem_sleep` =
`[s2idle]`). Hibernate, hybrid-sleep and suspend-then-hibernate stay masked. The 24/7 install had masked
`sleep.target` and `suspend.target`; they are unmasked now.

## How it wakes

Before suspending it arms the RTC alarm (`/sys/class/rtc/rtc0/wakealarm`) and reads it back. The alarm is set for the
heartbeat (`heartbeat_minutes` = **20**), or 2 minutes before the next `clashjobs submit --at` job if that is sooner.
**If the alarm cannot be armed and read back, it does not sleep.** If the box resumes more than 15 minutes after the
alarm (so the alarm did not wake it), automatic sleep turns itself off (`/etc/ai-server-2/power.disabled`) until
someone runs `ai-power enable`.

After a heartbeat wake with nothing to do it sleeps again after `heartbeat_grace_minutes` (**3**). Any ssh command
or job in that window holds it awake as usual.

| route | status (2026-10-09) |
|---|---|
| RTC heartbeat, at most 20 min | **works**: 5 of 5 test suspends woke on the alarm |
| A `clashjobs submit --at WHEN` job | **works** (same RTC alarm; `--at` takes ISO, `HH:MM` or `+30m`) |
| Wake-on-WLAN magic packet (MT7925, `wlp99s0`, MAC `cc:61:46:b6:34:c5`) | **does not wake it**. The packet is enabled and re-armed before every suspend, and the packets reach the NIC while the box is awake. 3 tries from s2idle, the last two with the PCIe bridge wake flags on and D3cold off, all slept to the RTC alarm. |
| Wake-on-LAN, Realtek 10GbE `enp97s0` / `enp98s0` (MACs `38:05:25:31:90:8a` / `:8b`) | armed (`Wake-on: g`, persistent via `/etc/systemd/network/10-ai-server-2-wol.link`, re-armed before every suspend). **Untested**: no cable yet. |
| Wake relay over Tailscale | not yet: the box is not on the relay's LAN (see below) |

So today the box wakes only on its RTC: within 20 minutes, or on time for an `--at` job. Submitters wait for it:

- **Mac:** `wake-ai-server-2` (ClashEngineering `ops/strixhalo/wake-ai-server-2`, linked into `~/.local/bin`).
  If the box answers ssh it returns at once. If the Mac is on the box's LAN (192.168.10.0/24) it sends the magic
  packets. Otherwise it runs `ssh root@wake-relay wake-ai-server-2`. Then it waits for ssh. `onbox.sh` and
  `push_runs.sh` call it and wait up to 23 min, which covers the heartbeat.
  *macOS gotcha:* "Local Network" privacy silently drops LAN UDP from a terminal or agent that was not granted it,
  and `sendto` still reports success. The script therefore sends from a one-shot `launchctl submit` job, which is not
  subject to that.
- **AI Server 1:** `C:\AI-Server\scripts\box.cmd`. If ssh cannot connect (exit 255), it sends a magic packet for the
  three MACs to `192.168.1.255` and retries for about 3 minutes. That wakes the box only once it is wired at the AI
  Server 1 site. Until then the heartbeat wakes it, and the retry just fails after about 3 minutes as before.
  Deployed 2026-10-09; the previous copy is `box.cmd.bak-20261009`. Keep the deployed file CRLF: it uses `goto`.

### When the box moves to the AI Server 1 site (wired)

1. Plug in `enp97s0`. netplan already matches `en*` with DHCP.
2. Test WoL while it is awake, then for real: `sudo ai-power test-suspend 300`, and send a packet from a LAN device
   (`wake-ai-server-2 --send` from the Mac on that LAN). If it is back within seconds, WoL works.
3. Add it to the wake relay (the Mac mini `wake-relay`, 192.168.1.63). As root on the mini, create
   `/usr/local/bin/wake-ai-server-2` next to the existing `wake-ai-server`: the same magic-packet sender with the
   MACs `38:05:25:31:90:8a 38:05:25:31:90:8b cc:61:46:b6:34:c5` and broadcast `192.168.1.255` (UDP 9 and 7).
   Optionally add a `/wake2` path to `wake-http-server.py`. `wake-ai-server-2` on the Mac already tries
   `ssh root@wake-relay wake-ai-server-2` whenever the Mac is not on the box's LAN.
4. On the Mac set `AIS2_LAN_IP`, `AIS2_LAN_PREFIX=192.168.1.` and `AIS2_BCAST=192.168.1.255` (or edit the defaults
   in the script).

## Commands (on the box)

```
ai-power status                 # what holds it awake, when it would sleep and wake, the last sleep
sudo ai-power disable [--why X] # stop automatic sleep (persists across reboots)
sudo ai-power enable
sudo ai-power hold 3h           # keep it awake for a while (unit keepawake-hold); sudo ai-power release
systemd-run --user --unit keepawake-NAME CMD     # hold it awake while CMD runs
systemd-inhibit --what=sleep CMD                 # same, through logind
clashjobs submit --at 03:00 -- CMD               # scheduled job; the box wakes for it
sudo ai-power test-suspend 120  # supervised manual suspend with an RTC wake (refuses while busy; --force)
ai-power log                    # journalctl -u ai-power
```

| | |
|---|---|
| Config | `/etc/ai-server-2/power.json`: `grace_minutes`, `heartbeat_minutes`, `heartbeat_grace_minutes`, `input_idle_minutes`, `llm_idle_minutes`, `busy_ports`, `cpu_busy_percent`, `net_busy_kbps`, and `busy_processes_extra` / `keep_awake_units_extra` (added to the defaults in `aipower.py`). Read on every poll; no restart needed. |
| State | `/run/ai-power/state.json` (what `status` prints), `/run/ai-power/last_resume.json` |
| History | `/var/log/ai-power.jsonl` (start, gate changes, suspend, resumed with what woke it, refusals) |
| Sleep hook | `/usr/lib/systemd/system-sleep/ai-server-2-power`: before suspend it pauses PID 1's hardware watchdog and re-arms Wake-on-WLAN, Wake-on-LAN and the PCI wake flags; after resume it restores the watchdog |
| Never | sleep the box any other way. logind is set to ignore idle, the suspend key and the lid (`/etc/systemd/logind.conf.d/90-ai-server-2.conf`). |

## Watchdog

The hardware watchdog had not been running. `sp5100_tco` is in Ubuntu's module blacklist, and systemd-modules-load
honours the blacklist, so `/etc/modules-load.d/90-watchdog.conf` never loaded it at boot. Both boots on 2026-10-09
logged "Failed to open any watchdog device". `ai-server-2-watchdog.service` (sysinit) now runs `modprobe sp5100_tco`
and makes PID 1 open the device: `/sys/class/watchdog/watchdog0/state` = `active`, timeout 120 s. The sleep hook pauses
it for the suspend, and a 180 s suspend did not reset the box. Whether a real hang reboots the box is still untested.

## Measured (2026-10-09, with other agents' jobs running)

| test | result |
|---|---|
| 5 suspends (`ai-power test-suspend`, 119 / 179 / 149 / 149 / 150 s) | all resumed by themselves on the RTC. Wi-Fi stayed associated, default route and Tailscale were back at once, `amdgpu` resumed with no errors ("SMU is resumed successfully"), `clash-jobs` and `clashlab-serve` stayed active, and running clashjobs carried on. |
| watchdog over a 180 s suspend | not tripped (uptime continued) |
| Wake-on-WLAN | did not wake (see above) |
| LLM after resume | not tested: the model was still downloading and `llm-gufo` was not running. Check `curl :8080` after the first sleep with the model loaded. |
| sleep depth | `amd_pmc: Last suspend didn't reach deepest state`: s2idle stops short of S0i3, so it draws more power asleep than it could. It still resumes reliably. |

## For the owner (things only you can do)

- **BIOS, AC power loss = Power On** (also in docs/15). A cut while asleep leaves it off otherwise.
- **BIOS, wake settings:** enable *Wake on LAN* / *PCIe wake* (PME) and disable *ErP* / deep-sleep power saving. Those
  settings decide whether the wired NIC can wake it, and they may be why Wake-on-WLAN does not.
- **Wake on the LAN today:** none works, so a submit can wait up to 20 min for the heartbeat. To make the box stay up,
  run `sudo ai-power disable` (or set `heartbeat_minutes` lower).

## The ClashLab site and sleep (2026-10-10)

The ClashLab site's main copy is on this box (https://ai-server-2.tail215694.ts.net/, `tailscale serve` -> :8787).
While the box is suspended the site does not answer; AI Server 1's :8787 redirect still points here. Serving keeps
nothing awake on its own (`tailscaled` and `clashlab serve` are not in `busy_processes`, :443/:8787 are not
`busy_ports`); only real viewing traffic over the network gate (> `net_busy_kbps` 1500 for ~1 min) does. The site
rebuild (`clashlab-update.service`) is a defer unit, and its recorder now stops at 12 videos per pass for recent
runs only, so it no longer pins the box awake.
