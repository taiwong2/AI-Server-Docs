# Wake and power

The machine sleeps when nobody needs it and wakes when there is work. This page
is how that works and how to wake it yourself.

## When it sleeps

Sleep needs **all** of these, continuously, for `grace_minutes` (default 8):

- nothing runnable in the queue
- no live GPU lease
- no attended logon session (RDP with recent input)
- no connected Sunshine stream
- console idle for at least `input_idle_minutes` (default 15)
- nothing listening on a `busy_ports` entry (default `[25565]`)

`python C:\AI-Server\scripts\jobqueue.py status` names whichever gate is
holding it awake. If the box is not sleeping when you expect, that command is
the answer, not a guess.

> **The Minecraft server on 25565 blocks sleep whenever it is running.** That is
> correct — people are connected — but it means auto-sleep effectively never
> fires while it is up. Remove the port from `busy_ports` when the server
> retires.

It suspends to **S3**, not hibernate. Hibernation is disabled precisely so that
`SetSuspendState` reaches S3, because S4 changes both Wake-on-LAN and wake-timer
behaviour.

## How it wakes — four routes

| Route | Latency | Needs |
|---|---|---|
| A job scheduled for a future time | at that time | nothing — armed before it sleeps |
| Wake-on-LAN from the LAN | seconds | a device on `192.168.1.0/24` |
| **Wake-on-LAN via the tailnet relay** | seconds | the `wake-relay` node online |
| Its own heartbeat | ≤ `heartbeat_minutes` (20) | nothing |

Before suspending, the runner arms a `WakeToRun` scheduled task for the
heartbeat, plus a one-shot for the earliest scheduled job. **If it cannot arm a
wake, it refuses to sleep** and says so — staying awake is strictly safer than
a box nothing can wake.

## Waking it from the LAN

Target: MAC `04:7C:16:3E:B4:6E`, IP `192.168.1.24`, broadcast `192.168.1.255`
(the *subnet* broadcast — `255.255.255.255` is commonly dropped), UDP 9 and 7.

From a Mac, `scripts/wake-pc.sh` in this repo. No Homebrew needed; macOS ships
python3.

```bash
./wake-pc.sh              # send, then wait for ping and ssh
./wake-pc.sh --send       # just send
```

## Waking it from anywhere — the relay

There is a Tailscale node called **`wake-relay`** (`100.127.179.9`, macOS) which
sits on the same LAN at `192.168.1.63`. Verified from the server:

```
pong from wake-relay (100.127.179.9) via 192.168.1.63:56611 in 114ms
```

Direct connection, not a DERP hop — it is genuinely LAN-adjacent. So the
beyond-LAN path is:

```
you, anywhere  ->  Tailscale  ->  wake-relay  ->  magic packet on 192.168.1.255  ->  server wakes
```

```bash
ssh <user>@100.127.179.9 './wake-pc.sh --send'
```

This is why "no instant wake from off the LAN" is **wrong for this network**.
Without a relay it would be true — the Netgear cannot forward a broadcast from
the WAN or hold a static ARP entry — but the relay makes the router's limitation
irrelevant.

**The relay only works while the relay is awake.** A MacBook that sleeps or goes
offline takes the beyond-LAN instant wake with it; the 20-minute heartbeat is
the fallback. If the relay is a laptop, disable its sleep or accept the
fallback.

## Proving a magic packet arrives — without sleeping anything

"WoL is configured" and "the packet from that machine reaches this NIC" are
different questions, and only the second matters. Test the second while the box
is **awake**, where a failure costs nothing:

```bash
python C:\AI-Server\scripts\wol-listen.py --seconds 120   # on the server
./wake-pc.sh --send                                        # on the sender
```

The listener prints the target MAC of anything it receives and says whether it
belongs to this box — so a wrong MAC, a wrong broadcast address, a sender on a
different subnet, or a switch dropping broadcasts all show up immediately.

Verified 2026-08-25: packets arrive on UDP 9 and 7 and are matched correctly.

This proves the LAN path. It cannot prove the NIC wakes the machine from S3 —
that is firmware.

## The safe sleep/wake test

```powershell
powershell -File C:\AI-Server\scripts\wake-test.ps1           # arm
# disconnect Sunshine/RDP, wait ~1 min for it to suspend, then wake it
powershell -File C:\AI-Server\scripts\wake-test.ps1 -Report   # what woke it
powershell -File C:\AI-Server\scripts\wake-test.ps1 -Restore  # put policy back
```

Arming shortens the heartbeat to 3 minutes and lifts the busy-port guard, so the
box has **two independent ways back**. Wakes in seconds → WoL works. Returns on
its own in ~3 minutes → WoL did not, the timer did, and nothing is stranded.

## Not yet proven

`powercfg /lastwake` reports **`Wake History Count - 0`**: this machine has never
woken from a timer or a packet. Wake timers are enabled, the NIC is wake-armed,
Fast Startup is off, S3 is available, and the queue's wake task has been observed
firing correctly while awake — but the S3 round trip itself is untested, because
testing it drops whatever session is driving it.

If both mechanisms fail, look for an **ErP / deep-sleep setting in the MSI
BIOS**, which disables exactly this. Recovery in the worst case is the power
button; nothing is damaged.

Update this section once the test has run.

## Never sleep the machine yourself

Exactly one thing decides: the queue runner. Do not call `SetSuspendState`,
`shutdown`, or `rundll32 powrprof.dll`, and do not change power plans. The old
idle monitor's sleep tier was removed for this reason.
